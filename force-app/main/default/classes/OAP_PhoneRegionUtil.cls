/**
 * OAP_PhoneRegionUtil
 *
 * Single source of truth for resolving OAP_Primary_Phone_Country_Code__c /
 * OAP_Other_Phone_Country_Code__c into a dial code.
 *
 * These are restricted picklists whose Label and API Name differ: "Canada
 * +1" -> CAN, "United Kingdom +44" -> UK, "India +91" -> IND, "Other" ->
 * OTH. Apex and SOQL read the API Name, so the stored value never carries
 * the dial code and must be mapped, not parsed. Writing a label-shaped
 * value ("United Kingdom +44") into either field fails at DML with
 * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST -- only API Names are valid.
 *
 * The mapping comes from the field describe (the labels do carry the dial
 * code), so a country added to the picklist needs no change here. Should
 * a label ever stop carrying its dial code, DIAL_CODE_BY_API_NAME below
 * is consulted as a fallback.
 *
 * Used by:
 *  - OAP_ApplicationFormHandler.toDialCode() — CFRIMS submission JSON
 *    (primary_phone_region / secondary_phone_region, expects "+1" format)
 *  - OAP_Cfrims2ChallengeController.resolveApplicantDialCode() — SMS/MFA
 *    verification (System.UserManagement.formatPhoneNumber expects the
 *    calling code WITHOUT the leading "+", e.g. "1" not "+1")
 */
public with sharing class OAP_PhoneRegionUtil {

    private static final Pattern DIAL_CODE_PATTERN = Pattern.compile('(\\+\\d+)\\s*$');

    // Fallback for API Names whose label carries no dial code. 'OTH' is
    // deliberately absent: "Other" has no dial code by definition.
    private static final Map<String, String> DIAL_CODE_BY_API_NAME = new Map<String, String>{
        'CAN' => '+1',
        'USA' => '+1',
        'UK'  => '+44',
        'IND' => '+91',
        'CHI' => '+86',
        'PHI' => '+63',
        'MEX' => '+52',
        'FRA' => '+33',
        'PAK' => '+92',
        'GER' => '+49',
        'ITA' => '+39',
        'SPA' => '+34',
        'AUS' => '+61',
        'NZE' => '+64',
        'BEL' => '+32',
        'NET' => '+31'
    };

    private static Map<String, String> describedDialCodeByApiName;

    /**
     * Returns the dial code WITH a leading "+" (e.g. "+1") for a picklist
     * API Name, or "" if the value is blank, is "Other" (OTH) -- a
     * legitimate selection with no dial code to give -- or maps to nothing.
     */
    public static String extractDialCode(String rawPhoneCountryValue) {
        if (String.isBlank(rawPhoneCountryValue)) return '';

        String apiName = rawPhoneCountryValue.trim().toUpperCase();

        String described = getDescribedDialCodeByApiName().get(apiName);
        if (String.isNotBlank(described)) {
            return described; // e.g. "UK" -> "+44"
        }

        if (DIAL_CODE_BY_API_NAME.containsKey(apiName)) {
            return DIAL_CODE_BY_API_NAME.get(apiName);
        }

        if (apiName == 'OTH' || apiName == 'OTHER') {
            // Expected case: applicant's country isn't in the standard list.
            return '';
        }

        System.debug(LoggingLevel.WARN,
            'OAP_PhoneRegionUtil.extractDialCode: no dial code for picklist '
            + 'API Name "' + rawPhoneCountryValue + '". If a new country was '
            + 'added, ensure its label ends in its dial code.');
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
     * The picklist API Name for a dial code (e.g. "+44" -> "UK"), or null
     * when no entry matches. Lets tests and data scripts set the field with
     * a value the restricted picklist accepts. Ambiguous codes shared by
     * several countries ("+1") resolve to the first matching entry.
     */
    public static String apiNameForDialCode(String dialCode) {
        if (String.isBlank(dialCode)) return null;

        String normalised = dialCode.trim().startsWith('+')
            ? dialCode.trim()
            : '+' + dialCode.trim();

        for (String apiName : getDescribedDialCodeByApiName().keySet()) {
            if (getDescribedDialCodeByApiName().get(apiName) == normalised) return apiName;
        }
        for (String apiName : DIAL_CODE_BY_API_NAME.keySet()) {
            if (DIAL_CODE_BY_API_NAME.get(apiName) == normalised) return apiName;
        }
        return null;
    }

    /**
     * API Name -> dial code, built from the picklist labels on
     * OAP_Primary_Phone_Country_Code__c. Both country-code fields share the
     * same value set, so one describe covers them.
     */
    private static Map<String, String> getDescribedDialCodeByApiName() {
        if (describedDialCodeByApiName != null) return describedDialCodeByApiName;

        describedDialCodeByApiName = new Map<String, String>();

        for (Schema.PicklistEntry entry :
                Account.OAP_Primary_Phone_Country_Code__c
                    .getDescribe()
                    .getPicklistValues()) {

            Matcher m = DIAL_CODE_PATTERN.matcher(entry.getLabel().trim());
            if (m.find()) {
                describedDialCodeByApiName.put(entry.getValue().toUpperCase(), m.group(1));
            }
        }

        return describedDialCodeByApiName;
    }
}
