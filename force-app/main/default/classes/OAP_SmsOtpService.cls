/**
 * Application-owned SMS one-time-password service for the Challenge flow's
 * Option 1.
 *
 * Why this exists: the previous implementation used Salesforce Identity
 * Verification (System.UserManagement.initRegisterVerificationMethod /
 * verifyVerificationMethod). On PP2-TRG that call refuses to enrol the portal
 * user and returns "We cannot verify this phone number. Check its format and
 * try again." even for a valid E.164 number, and it fails BEFORE the custom
 * OTP delivery handler is invoked — the debug log of a failed attempt contains
 * no CALLOUT_REQUEST at all, so no SMS is ever dispatched. Identity
 * Verification additionally depends on Identity Verification Credits, the
 * portal licence/profile permitting SMS, and a TwoFactorMethodsInfo enrolment.
 *
 * This service instead generates and validates the code itself and sends it
 * through the same Google CCAI path the OmniScript uses
 * (OAP_CustomOTPDeliveryHandler.sendOtp), which is known to deliver. The
 * trade-off is that expiry, attempt limiting and resend throttling are our
 * responsibility; they are implemented below.
 *
 * The plaintext code is never stored — only a SHA-256 digest of the code and
 * the running user's Id, held in the session cache partition alongside the
 * rest of the challenge state.
 */
public with sharing class OAP_SmsOtpService {

    public class SmsOtpException extends Exception {}

    private static final String  PARTITION               = 'local.cfrims2';
    private static final String  KEY_PREFIX              = 'smsOtp';
    private static final Integer CODE_TTL_SECONDS        = 300;
    private static final Integer CACHE_TTL_SECONDS       = 900;
    private static final Integer MAX_VERIFY_ATTEMPTS     = 5;
    private static final Integer RESEND_COOLDOWN_SECONDS = 30;

    /**
     * Generates a code, sends it to the given E.164 number and returns the
     * masked number for display. Throws SmsOtpException with a user-safe
     * message when the code cannot be sent.
     */
    public static String sendCode(String e164Phone) {
        if (String.isBlank(e164Phone) || !Pattern.matches('^\\+[1-9][0-9]{7,14}$', e164Phone)) {
            throw new SmsOtpException(
                'We could not use the phone number on file. Please choose a different option.');
        }

        Challenge existing = load();
        if (existing != null
                && existing.sentAt != null
                && (nowMillis() - existing.sentAt) < (RESEND_COOLDOWN_SECONDS * 1000)) {
            throw new SmsOtpException(
                'A code was just sent. Please wait a few seconds before requesting another.');
        }

        String code = generateCode();

        // No parentheses in the message: OAP_CustomOTPDeliveryHandler.sendOtp
        // reduces the message to substringBetween('(', ')') when a bracketed
        // section is present, which would strip the code out of the SMS.
        String message = 'Your Canadian Armed Forces verification code is '
            + code + '. It expires in 5 minutes.';

        try {
            OAP_CustomOTPDeliveryHandler.SmsResult result =
                OAP_CustomOTPDeliveryHandler.sendOtp(
                    new OAP_CustomOTPDeliveryHandler.SmsRequest(e164Phone, message));

            if (result == null || result.success != true) {
                throw new SmsOtpException(
                    'We could not send the code. Please try again or choose a different option.');
            }
        } catch (SmsOtpException e) {
            throw e;
        } catch (Exception e) {
            // sendOtp logs the failure to the CFRIMS API log and throws
            // OtpDeliveryException / CalloutException; keep the detail server-side.
            System.debug(LoggingLevel.ERROR, '[OAP_SmsOtpService.sendCode] '
                + e.getTypeName() + ': ' + e.getMessage());
            throw new SmsOtpException(
                'We could not send the code. Please try again or choose a different option.');
        }

        Challenge challenge = new Challenge();
        challenge.codeHash  = digest(code);
        challenge.sentAt    = nowMillis();
        challenge.expiresAt = challenge.sentAt + (CODE_TTL_SECONDS * 1000);
        challenge.attempts  = 0;
        store(challenge);

        return maskPhone(e164Phone);
    }

    /**
     * Validates a code the applicant typed. Returns false for a wrong code and
     * throws SmsOtpException when no code is outstanding, it has expired, or
     * the attempt limit is reached — those need a distinct message from
     * "wrong code, N attempts left".
     */
    public static Boolean verifyCode(String code) {
        Challenge challenge = load();
        if (challenge == null) {
            throw new SmsOtpException(
                'No code is outstanding. Please request a new code.');
        }
        if (challenge.expiresAt == null || nowMillis() > challenge.expiresAt) {
            clear();
            throw new SmsOtpException('That code has expired. Please request a new one.');
        }
        if (challenge.attempts != null && challenge.attempts >= MAX_VERIFY_ATTEMPTS) {
            clear();
            throw new SmsOtpException(
                'Too many incorrect codes were entered. Please request a new code.');
        }

        String supplied = String.isBlank(code) ? '' : code.trim();
        if (digest(supplied) == challenge.codeHash) {
            clear();  // single use
            return true;
        }

        challenge.attempts = (challenge.attempts == null ? 0 : challenge.attempts) + 1;
        store(challenge);
        return false;
    }

    public static String maskPhone(String phone) {
        if (String.isBlank(phone)) return null;
        String digits = phone.replaceAll('[^0-9]', '');
        return digits.length() <= 4 ? '***' + digits : '***-***-' + digits.right(4);
    }

    // ── internals ────────────────────────────────────────────────────────────

    private static String generateCode() {
        Integer value = Math.mod(Math.abs(Crypto.getRandomInteger()), 1000000);
        return String.valueOf(value).leftPad(6, '0');
    }

    private static String digest(String code) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256',
                Blob.valueOf(code + '|' + UserInfo.getUserId())));
    }

    private static Long nowMillis() {
        return DateTime.now().getTime();
    }

    private static String cacheKey() {
        // Platform cache keys allow alphanumeric characters only.
        return KEY_PREFIX + UserInfo.getUserId();
    }

    private static Challenge load() {
        try {
            Object raw = Cache.Session.getPartition(PARTITION).get(cacheKey());
            if (raw == null) return null;
            return (Challenge) JSON.deserialize(String.valueOf(raw), Challenge.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[OAP_SmsOtpService.load] ' + e.getMessage());
            return null;
        }
    }

    private static void store(Challenge challenge) {
        Cache.Session.getPartition(PARTITION).put(
            cacheKey(), JSON.serialize(challenge), CACHE_TTL_SECONDS);
    }

    private static void clear() {
        try {
            Cache.Session.getPartition(PARTITION).remove(cacheKey());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[OAP_SmsOtpService.clear] ' + e.getMessage());
        }
    }

    private class Challenge {
        public String  codeHash;
        public Long    sentAt;
        public Long    expiresAt;
        public Integer attempts;
    }
}
