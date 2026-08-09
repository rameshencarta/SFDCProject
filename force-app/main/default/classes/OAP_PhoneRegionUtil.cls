/**
 * OAP_PhoneRegionUtil
 *
 * Single source of truth for parsing OAP_Primary_Phone_Country_Code__c /
 * OAP_Other_Phone_Country_Code__c picklist values into a dial code.
 *
 * These fields do NOT store a bare ISO country code — their real picklist
 * values are formatted like "Canada +1", "United Kingdom +44", ...,
 * "Other" (confirmed via Setup > Object Manager > Account > Fields, Aug
 * 2026). This class extracts the trailing "+<digits>" rather than assuming
 * any particular bare-code format.
 *
 * Used by:
 *  - OAP_ApplicationFormHandler.toDialCode() — CFRIMS submission JSON
 *    (primary_phone_region / secondary_phone_region, expects "+1" format)
 *  - OAP_Cfrims2ChallengeController.resolveApplicantDialCode() — SMS/MFA
 *    verification (System.UserManagement.formatPhoneNumber expects the
 *    calling code WITHOUT the leading "+", e.g. "1" not "+1")
 *
 * Extracted as a shared class (Aug 2026) so both call sites parse this
 * field identically instead of maintaining two copies of the same regex
 * that could silently drift apart.
 */
public with sharing class OAP_PhoneRegionUtil {

    private static final Pattern DIAL_CODE_PATTERN = Pattern.compile('(\\+\\d+)\\s*$');

    /**
     * Returns the dial code WITH a leading "+" (e.g. "+1"), or "" if the
     * value is blank, is "Other" (a legitimate selection with no dial code
     * to give), or doesn't match the expected "Country +Code" format.
     */
    public static String extractDialCode(String rawPhoneCountryValue) {
        if (String.isBlank(rawPhoneCountryValue)) return '';

        String trimmed = rawPhoneCountryValue.trim();
        Matcher m = DIAL_CODE_PATTERN.matcher(trimmed);
        if (m.find()) {
            return m.group(1); // e.g. "Canada +1" -> "+1"
        }

        if (trimmed.equalsIgnoreCase('Other')) {
            // Expected case: applicant's country isn't in the standard list.
            return '';
        }

        System.debug(LoggingLevel.WARN,
            'OAP_PhoneRegionUtil.extractDialCode: could not extract a dial '
            + 'code from "' + rawPhoneCountryValue + '".');
        return '';
    }

    /**
     * Convenience wrapper for callers that need the calling code WITHOUT
     * the leading "+" (e.g. System.UserManagement.formatPhoneNumber, which
     * expects "1" not "+1"). Falls back to fallbackDigitsOnly (also without
     * "+") when extraction yields nothing.
     */
    public static String extractDialCodeDigitsOnly(String rawPhoneCountryValue, String fallbackDigitsOnly) {
        String withPlus = extractDialCode(rawPhoneCountryValue);
        if (String.isBlank(withPlus)) return fallbackDigitsOnly;
        return withPlus.startsWith('+') ? withPlus.substring(1) : withPlus;
    }
}
