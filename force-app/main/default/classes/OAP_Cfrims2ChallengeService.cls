/**
 * @description Challenge validation service for CFRIMS merge flow.
 * @author Ramesh / DND
 * @date 2026-05-26
 * @group Integration Framework
 *
 * Version                     Date                          Author
 * v1                          26-May-2026                   Ramesh - Initial version
 * v2                          17-Jun-2026                   Ramesh - Renamed to OAP_Cfrims2ChallengeService
 *                                                               Updated CFRIMS_ApiClient references
 *                                                               to OAP_CFRIMS_ApiClient
 */
public with sharing class OAP_Cfrims2ChallengeService {

    public static Boolean validate(String optionCode, Map<String, Object> answer, String email) {
        Map<String, String> handshake = OAP_Cfrims2SessionCache.getHandshake(UserInfo.getUserId());
        if (handshake == null) {
            throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception('No active CFRIMS session - please sign in again.');
        }
        if (optionCode == '2') {
            return validateSecurityQuestionLocally(email, answer);
        }
       
        if (optionCode == '1') {
            return validateSmsCodeLocally(answer);
        }
        if (optionCode == '3' || optionCode == '4') {
            CasePayload cached = OAP_Cfrims2SessionCache.getCasePayload(UserInfo.getUserId());
            Boolean hasReference = optionCode == '3'
                ? cached != null && String.isNotBlank(cached.service_nb) && String.isNotBlank(cached.dob)
                : cached != null && String.isNotBlank(cached.last_name)
                    && String.isNotBlank(cached.dob) && String.isNotBlank(cached.city_birth);
            if (hasReference) {
                return optionCode == '3'
                    ? validateServiceNumberLocally(email, answer, cached)
                    : validateBirthDetailsLocally(email, answer, cached);
            }
        }
        Integer optionNumber = Integer.valueOf(optionCode);
        Map<String, Object> payload = buildPayload(optionCode, answer);

        OAP_CFRIMS_ApiClient.ChallengeResponse resp = OAP_CFRIMS_ApiClient.verifyChallenge(
            handshake, email, optionNumber, payload
        );
        return interpret(resp);
    }

   
    public static String requestSmsCode(String email, String phoneOnFile) {
        if (String.isBlank(phoneOnFile)) {
            throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception(
                'No phone number on file for this applicant.');
        }

        Boolean alreadyVerified = false;
        try {
            List<TwoFactorMethodsInfo> info = [
                SELECT HasUserVerifiedMobileNumber
                FROM TwoFactorMethodsInfo
                WHERE UserId = :UserInfo.getUserId()
            ];
            alreadyVerified = !info.isEmpty() && info[0].HasUserVerifiedMobileNumber;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2ChallengeService: TwoFactorMethodsInfo query failed, '
                + 'assuming unverified: ' + e.getMessage());
        }

        
        if (alreadyVerified) {
            String identifier = System.UserManagement.initVerificationMethod(
                Auth.VerificationMethod.SMS
            );
            OAP_Cfrims2SessionCache.putOtpIdentifier(UserInfo.getUserId(), identifier);
            OAP_Cfrims2SessionCache.putOtpMode(UserInfo.getUserId(), 'verify');
        } else {
            String errorMsg = System.UserManagement.initRegisterVerificationMethod(
                Auth.VerificationMethod.SMS
            );
            if (String.isNotBlank(errorMsg)) {
                throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception(
                    'Could not send code: ' + errorMsg);
            }
            OAP_Cfrims2SessionCache.putOtpMode(UserInfo.getUserId(), 'register');
        }

        return MaskUtil.maskPhone(phoneOnFile);
    }

   
    @TestVisible
    public static String toE164(String rawPhone) {
        if (String.isBlank(rawPhone)) return rawPhone;
        String digitsOnly = rawPhone.replaceAll('[^0-9]', '');
        if (digitsOnly.length() == 10) {
            return '+1' + digitsOnly;
        }
        if (digitsOnly.length() == 11 && digitsOnly.startsWith('1')) {
            return '+' + digitsOnly;
        }
        return rawPhone; // already E.164 or an unrecognized format — leave alone
    }

    // UserManagement verification cannot be mocked or executed in Apex tests
    // (it raises an uncatchable System.UnexpectedException); tests set this
    // stub instead of calling through to the platform.
    @TestVisible private static Boolean stubVerifyResult;

    @TestVisible
    private static Boolean validateSmsCodeLocally(Map<String, Object> answer) {
        String code = answer != null && answer.get('code') != null
            ? String.valueOf(answer.get('code')) : null;
        if (String.isBlank(code)) return false;

        String mode = OAP_Cfrims2SessionCache.getOtpMode(UserInfo.getUserId());

        if ('register' == mode) {
           
            String errorMsg = System.UserManagement.verifyRegisterVerificationMethod(
                code, Auth.VerificationMethod.SMS
            );
            Boolean success = String.isBlank(errorMsg);
            if (success) {
                OAP_Cfrims2SessionCache.clearOtpIdentifier(UserInfo.getUserId());
            }
            return success;
        }

        String identifier = OAP_Cfrims2SessionCache.getOtpIdentifier(UserInfo.getUserId());
        if (String.isBlank(identifier)) {
            throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception(
                'No pending SMS verification found. Please request a new code.');
        }
        Boolean verified;
        if (Test.isRunningTest() && stubVerifyResult != null) {
            verified = stubVerifyResult;
        } else {
            Auth.VerificationResult result = System.UserManagement.verifyVerificationMethod(
                identifier, code, Auth.VerificationMethod.SMS
            );
            verified = result.success;
        }
        if (verified) {
            OAP_Cfrims2SessionCache.clearOtpIdentifier(UserInfo.getUserId());
        }
        return verified;
    }

    @TestVisible
    private static Boolean validateSecurityQuestionLocally(
            String email, Map<String, Object> answer) {
        String questionText  = (String) answer.get('question');
        String userPlaintext = (String) answer.get('answer');
        if (String.isBlank(questionText) || userPlaintext == null) {
            logAttempt(email, questionText, false, 'Missing question or answer');
            return false;
        }
        CasePayload payload = OAP_Cfrims2SessionCache.getCasePayload(UserInfo.getUserId());
        String storedHash = findStoredHashForQuestion(payload, questionText);
        if (String.isBlank(storedHash)) {
            System.debug(LoggingLevel.WARN, 'No stored hash found for question: ' + questionText);
            logAttempt(email, questionText, false, 'Question not in payload');
            return false;
        }
        String computedHash = getHash(userPlaintext);
        Boolean match = computedHash != null && computedHash.equalsIgnoreCase(storedHash);
        logAttempt(email, questionText, match, match ? 'Hash match' : 'Hash mismatch');
        return match;
    }

    @TestVisible
    private static Boolean validateServiceNumberLocally(
            String email, Map<String, Object> answer, CasePayload payload) {
        String svc = normaliseServiceNumber(answerString(answer, 'serviceNumber'));
        String dob = normaliseDate(answerString(answer, 'dob'));
        Boolean match = String.isNotBlank(svc) && String.isNotBlank(dob)
            && svc == normaliseServiceNumber(payload.service_nb)
            && dob == normaliseDate(payload.dob);
        System.debug(LoggingLevel.INFO, '[Challenge option 3 attempt] email=' + email
            + ' success=' + match);
        return match;
    }

    @TestVisible
    private static Boolean validateBirthDetailsLocally(
            String email, Map<String, Object> answer, CasePayload payload) {
        String last = normaliseText(answerString(answer, 'lastName'));
        String dob  = normaliseDate(answerString(answer, 'dob'));
        String city = normaliseText(answerString(answer, 'cityOfBirth'));
        Boolean match = String.isNotBlank(last) && String.isNotBlank(dob) && String.isNotBlank(city)
            && last == normaliseText(payload.last_name)
            && dob  == normaliseDate(payload.dob)
            && city == normaliseText(payload.city_birth);
        System.debug(LoggingLevel.INFO, '[Challenge option 4 attempt] email=' + email
            + ' success=' + match);
        return match;
    }

    private static String answerString(Map<String, Object> answer, String key) {
        return answer == null || answer.get(key) == null ? null : String.valueOf(answer.get(key));
    }

    @TestVisible
    private static String normaliseServiceNumber(String raw) {
        return raw == null ? null : raw.replaceAll('[^A-Za-z0-9]', '').toUpperCase();
    }

    // Case-, whitespace- and accent-insensitive comparison key.
    @TestVisible
    private static String normaliseText(String raw) {
        if (raw == null) return null;
        String s = raw.trim().toLowerCase().replaceAll('\\s+', ' ');
        String accented = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿœæ';
        String to   = 'aaaaaaceeeeiiiinooooouuuuyyoa';
        for (Integer i = 0; i < accented.length(); i++) {
            s = s.replace(accented.substring(i, i + 1), to.substring(i, i + 1));
        }
        return s;
    }

    // Accepts yyyy-MM-dd, dd-MMM-yyyy (CFRIMS), dd/MM/yyyy, yyyy/MM/dd, yyyyMMdd; returns yyyy-MM-dd.
    @TestVisible
    private static String normaliseDate(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.trim();
        if (Pattern.matches('^\\d{4}-\\d{2}-\\d{2}.*', s)) {
            return s.substring(0, 10);
        }
        Matcher m = Pattern.compile('^(\\d{1,2})[-/ ]([\\p{L}]{3,})[-/ ,]+(\\d{4})$').matcher(s);
        if (m.matches()) {
            Integer month = monthFromName(m.group(2));
            if (month == null) return s;
            return pad(Integer.valueOf(m.group(3)), 4) + '-' + pad(month, 2) + '-' + pad(Integer.valueOf(m.group(1)), 2);
        }
        m = Pattern.compile('^([\\p{L}]{3,})\\.? (\\d{1,2}),? (\\d{4})$').matcher(s);
        if (m.matches()) {
            Integer month = monthFromName(m.group(1));
            if (month == null) return s;
            return pad(Integer.valueOf(m.group(3)), 4) + '-' + pad(month, 2) + '-' + pad(Integer.valueOf(m.group(2)), 2);
        }
        m = Pattern.compile('^(\\d{4})[/.](\\d{1,2})[/.](\\d{1,2})$').matcher(s);
        if (m.matches()) {
            return pad(Integer.valueOf(m.group(1)), 4) + '-' + pad(Integer.valueOf(m.group(2)), 2) + '-' + pad(Integer.valueOf(m.group(3)), 2);
        }
        m = Pattern.compile('^(\\d{1,2})[-/.](\\d{1,2})[-/.](\\d{4})$').matcher(s);
        if (m.matches()) {
            return pad(Integer.valueOf(m.group(3)), 4) + '-' + pad(Integer.valueOf(m.group(2)), 2) + '-' + pad(Integer.valueOf(m.group(1)), 2);
        }
        if (Pattern.matches('^\\d{8}$', s)) {
            return s.substring(0, 4) + '-' + s.substring(4, 6) + '-' + s.substring(6, 8);
        }
        return s;
    }

    private static Integer monthFromName(String name) {
        Map<String, Integer> months = new Map<String, Integer>{
            'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
            'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12,
            'fev' => 2, 'avr' => 4, 'mai' => 5, 'jui' => 6, 'aou' => 8
        };
        return months.get(normaliseText(name).left(3));
    }

    private static String pad(Integer n, Integer width) {
        String s = String.valueOf(n);
        while (s.length() < width) s = '0' + s;
        return s;
    }

    @TestVisible
    private static String getHash(String plaintext) {
        if (plaintext == null) return null;
        CFRIMS_Config__mdt cfg = CFRIMS_Config__mdt.getInstance('CFRIMS_Integration_Sandbox');
        String salt = (cfg != null && String.isNotBlank(cfg.hashsalt__c))
            ? cfg.hashsalt__c : 'default_fallback_salt';
        Blob target = Blob.valueOf(salt + plaintext);
        Blob digest = Crypto.generateDigest('SHA-1', target);
        return EncodingUtil.convertToHex(digest);
    }

    private static String findStoredHashForQuestion(
            CasePayload payload, String questionText) {
        if (payload == null || payload.security_question == null
            || payload.security_question.isEmpty() || String.isBlank(questionText)) {
            return null;
        }
        String target = questionText.trim().toLowerCase();
        for (Cfrims2SecurityQuestion q : payload.security_question) {
            if (q == null || String.isBlank(q.question)) continue;
            if (q.question.trim().toLowerCase() == target) return q.answer;
        }
        return null;
    }

    private static void logAttempt(String email, String questionText, Boolean success, String detail) {
        System.debug(LoggingLevel.INFO,
            '[Challenge option 2 attempt] email=' + email
            + ' question=' + questionText
            + ' success=' + success
            + ' detail=' + detail);
    }

    private static Map<String, Object> buildPayload(String optionCode, Map<String, Object> answer) {
        switch on optionCode {
            when '1' {
                return new Map<String, Object>{ 'code' => (String) answer.get('code') };
            }
            when '2' {
                return new Map<String, Object>{
                    'question' => (String) answer.get('question'),
                    'answer'   => (String) answer.get('answer')
                };
            }
            when '3' {
                return new Map<String, Object>{
                    'service_nb' => (String) answer.get('serviceNumber'),
                    'dob'        => (String) answer.get('dob')
                };
            }
            when '4' {
                return new Map<String, Object>{
                    'last_name'  => (String) answer.get('lastName'),
                    'dob'        => (String) answer.get('dob'),
                    'city_birth' => (String) answer.get('cityOfBirth')
                };
            }
            when else {
                throw new IllegalArgumentException('Unsupported option for validation: ' + optionCode);
            }
        }
    }

    private static Boolean interpret(OAP_CFRIMS_ApiClient.ChallengeResponse resp) {
        if (resp.res.getStatusCode() != 200 || String.isBlank(resp.decryptedBody)) return false;
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(resp.decryptedBody);
            if (body.containsKey('valid'))  return body.get('valid') == true;
            if (body.containsKey('status')) {
                String s = String.valueOf(body.get('status')).toUpperCase();
                return s == 'PASSED' || s == 'VALID' || s == 'SUCCESS';
            }
            if (body.containsKey('result')) {
                Object r = body.get('result');
                return r == 1 || r == true || String.valueOf(r) == '1';
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not parse challenge response: ' + e.getMessage());
        }
        return false;
    }

    private static String extractField(String body, String fieldName) {
        if (String.isBlank(body)) return null;
        try {
            Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(body);
            return (String) m.get(fieldName);
        } catch (Exception e) { return null; }
    }

    public static Cfrims2SecurityQuestion pickDifferentQuestion(
            String currentQuestionText, List<Cfrims2SecurityQuestion> all) {
        if (all == null || all.size() <= 1) {
            return all == null || all.isEmpty() ? null : all[0];
        }
        String current = currentQuestionText == null ? null : currentQuestionText.trim();
        List<Cfrims2SecurityQuestion> remaining = new List<Cfrims2SecurityQuestion>();
        for (Cfrims2SecurityQuestion q : all) {
            String text = q != null && q.question != null ? q.question.trim() : null;
            if (text != current) remaining.add(q);
        }
        if (remaining.isEmpty()) return all[0];
        Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), remaining.size());
        return remaining[idx];
    }
}