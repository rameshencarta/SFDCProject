/**
 * OAP_PhoneRegionUtil
 *
 * Single source of truth for parsing OAP_Primary_Phone_Country_Code__c /
 * OAP_Other_Phone_Country_Code__c picklist values into a dial code.
 *
 * The picklist labels carry the dial code ("Canada +1", "United Kingdom
 * +44", ..., "Other"), but the API names do not ("CAN", "UK", "OTH") --
 * and Apex reads the API name, not the label. So the dial code is resolved
 * from the field describe rather than by parsing the stored value, which
 * would otherwise always miss and fall back to +1.
 *
 * Reading it from the describe means new picklist entries need no code
 * change here, as long as their label ends in the dial code.
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

    private static Map<String, String> dialCodeByApiName;

    /**
     * Returns the dial code WITH a leading "+" (e.g. "+1"), or "" if the
     * value is blank, is "Other" (a legitimate selection with no dial code
     * to give), or doesn't match the expected "Country +Code" format.
     */
    public static String extractDialCode(String rawPhoneCountryValue) {
        if (String.isBlank(rawPhoneCountryValue)) return '';

        String trimmed = rawPhoneCountryValue.trim();

        // Handles a value that already carries the dial code, e.g. when the
        // API name and label match.
        Matcher m = DIAL_CODE_PATTERN.matcher(trimmed);
        if (m.find()) {
            return m.group(1); // e.g. "Canada +1" -> "+1"
        }

        String fromApiName = getDialCodeByApiName().get(trimmed.toUpperCase());
        if (String.isNotBlank(fromApiName)) {
            return fromApiName; // e.g. "IND" -> "+91"
        }

        if (trimmed.equalsIgnoreCase('Other') || trimmed.equalsIgnoreCase('OTH')) {
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

    /**
     * API name -> dial code, built from the picklist labels on
     * OAP_Primary_Phone_Country_Code__c. Both country-code fields share the
     * same value set, so one describe covers them.
     */
    private static Map<String, String> getDialCodeByApiName() {
        if (dialCodeByApiName != null) return dialCodeByApiName;

        dialCodeByApiName = new Map<String, String>();

        for (Schema.PicklistEntry entry :
                Account.OAP_Primary_Phone_Country_Code__c
                    .getDescribe()
                    .getPicklistValues()) {

            Matcher m = DIAL_CODE_PATTERN.matcher(entry.getLabel().trim());
            if (m.find()) {
                dialCodeByApiName.put(entry.getValue().toUpperCase(), m.group(1));
            }
        }

        return dialCodeByApiName;
    }
}
