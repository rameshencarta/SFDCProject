/**
 * @File Name        : ChallengeFlowController.cls
 * @Description      : Controller for the CFRIMS Challenge Flow LWC.
 *                     Handles identity verification when a new registration
 *                     matches an existing record in CFRIMS.
 *
 *                     Flow summary (from the CFRIMS Challenge Flow diagram):
 *                       1. New user registers -> API call checks CFRIMS
 *                       2. User exists? No  -> submit data to CFRIMS, proceed
 *                       3. User exists? Yes -> upsert data in Salesforce,
 *                          then evaluate merge flags:
 *                            - manual_merge_required=0 AND require_merge=1
 *                              -> present Challenge Questions (Option 1)
 *                            - manual_merge_required=1 AND merge_approved=0
 *                              -> no merge needed, route by application_completed
 *                       4. Challenge passed?  Yes -> route by application_completed
 *                       5. Challenge failed?  No  -> escalate to CFRG (Option 5)
 *
 * @Author           : Devin AI
 * @Last Modified On : April 28, 2026
 **/
public with sharing class ChallengeFlowController {

    // Maximum verification attempts before escalation
    private static final Integer MAX_ATTEMPTS = 3;

    /* ============================================================
     * Inner classes / DTOs
     * ============================================================ */

    /**
     * Wrapper for the CFRIMS challenge payload.
     * Mirrors the JSON structure returned by the external system.
     */
    public class ChallengeData {
        @AuraEnabled public Integer application_completed;
        @AuraEnabled public Integer require_merge;
        @AuraEnabled public Integer manual_merge_required;
        @AuraEnabled public Integer merge_approved;
        @AuraEnabled public Integer option1;
        @AuraEnabled public Integer option2;
        @AuraEnabled public Integer option3;
        @AuraEnabled public Integer option4;
        @AuraEnabled public List<SecurityQuestion> security_question;
        @AuraEnabled public String  service_nb;
        @AuraEnabled public String  dob;
        @AuraEnabled public String  phone;
        @AuraEnabled public String  last_name;
        @AuraEnabled public String  city_birth;
        @AuraEnabled public ApplicantData Applicant_data;
    }

    public class SecurityQuestion {
        @AuraEnabled public String question;
        @AuraEnabled public String answer;  // SHA-1 hex digest (uppercase)
    }

    public class ApplicantData {
        @AuraEnabled public PersonalInfo personal_info;
        @AuraEnabled public String       complete;
    }

    public class PersonalInfo {
        @AuraEnabled public String pers_GivenName;
        @AuraEnabled public String pers_Surname;
        @AuraEnabled public String pers_DateOfBirth;
        @AuraEnabled public String alpha_nb;
        @AuraEnabled public String pers_DateOfBirthCity;
        @AuraEnabled public String pers_DateOfBirthCountry;
        @AuraEnabled public String service_nb;
    }

    /**
     * Result returned to the LWC after each verification attempt.
     */
    public class VerificationResult {
        @AuraEnabled public Boolean passed;
        @AuraEnabled public String  message;
        @AuraEnabled public String  nextRoute;  // 'dashboard' | 'resume' | 'escalate' | null
        @AuraEnabled public Integer attemptsRemaining;

        public VerificationResult() {
            this.passed = false;
            this.attemptsRemaining = MAX_ATTEMPTS;
        }
    }

    /**
     * Result of evaluating merge flags to decide the initial route.
     */
    public class MergeDecisionResult {
        @AuraEnabled public Boolean showChallenge;       // true  = present challenge flow
        @AuraEnabled public Boolean noMergeNeeded;       // true  = skip challenge, route directly
        @AuraEnabled public String  directRoute;         // 'dashboard' | 'resume' | null
        @AuraEnabled public String  existingRecordLabel; // e.g. "Aboap20251117t4 · A844277"
        @AuraEnabled public List<QuestionDisplay> questions; // sanitised questions (no answers)
        @AuraEnabled public List<Integer> availableOptions;
    }

    /**
     * Question sent to client (answer hash is NEVER exposed).
     */
    public class QuestionDisplay {
        @AuraEnabled public Integer index;
        @AuraEnabled public String  question;

        public QuestionDisplay(Integer idx, String q) {
            this.index = idx;
            this.question = q;
        }
    }

    /* ============================================================
     * Public Aura-enabled methods
     * ============================================================ */

    /**
     * Evaluate the CFRIMS payload and decide whether to show the
     * challenge flow or route the user directly.
     *
     * Called once when the LWC initialises.
     *
     * @param  payloadJson  Serialised ChallengeData JSON from CFRIMS
     * @return MergeDecisionResult
     */
    @AuraEnabled
    public static MergeDecisionResult evaluateMergeDecision(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('Challenge payload is required.');
        }

        ChallengeData data;
        try {
            data = (ChallengeData) JSON.deserialize(payloadJson, ChallengeData.class);
        } catch (Exception e) {
            throw new AuraHandledException('Invalid challenge payload: ' + e.getMessage());
        }

        MergeDecisionResult result = new MergeDecisionResult();

        // Build existing-record label for the UI
        String surname = '';
        String alphaNb = '';
        if (data.Applicant_data != null && data.Applicant_data.personal_info != null) {
            surname = data.Applicant_data.personal_info.pers_Surname != null
                ? data.Applicant_data.personal_info.pers_Surname : '';
            alphaNb = data.Applicant_data.personal_info.alpha_nb != null
                ? data.Applicant_data.personal_info.alpha_nb : '';
        }
        result.existingRecordLabel = (String.isNotBlank(surname) ? surname : '') +
            (String.isNotBlank(alphaNb) ? ' \u00B7 ' + alphaNb : '');

        /*
         * Decision tree (from the detailed flow diagram page 2):
         *
         * manual_merge_required = 0:
         *   require_merge = 1 -> show challenge (Option 1)
         *   require_merge = 0 -> no merge needed, route by application_completed
         *
         * manual_merge_required = 1:
         *   merge_approved = 1 -> challenge already approved, route by application_completed
         *   merge_approved = 0 -> no merge needed yet, route by application_completed
         */
        if (data.manual_merge_required == 0 && data.require_merge == 1) {
            result.showChallenge = true;
            result.noMergeNeeded = false;

            // Build available options list
            result.availableOptions = new List<Integer>();
            if (data.option1 == 1 && data.security_question != null && !data.security_question.isEmpty()) {
                result.availableOptions.add(1);
            }
            if (data.option2 == 1) {
                result.availableOptions.add(2);
            }
            if (data.option3 == 1 && String.isNotBlank(data.service_nb)) {
                result.availableOptions.add(3);
            }
            if (data.option4 == 1) {
                result.availableOptions.add(4);
            }

            // Build sanitised question list (no answers sent to client)
            result.questions = new List<QuestionDisplay>();
            if (data.security_question != null) {
                for (Integer i = 0; i < data.security_question.size(); i++) {
                    result.questions.add(
                        new QuestionDisplay(i, data.security_question[i].question)
                    );
                }
            }
        } else {
            result.showChallenge = false;
            result.noMergeNeeded = true;
            result.directRoute = (data.application_completed == 1) ? 'dashboard' : 'resume';
        }

        return result;
    }

    /**
     * Verify the user's answers to the security questions (Option 1).
     *
     * @param  payloadJson    Original ChallengeData JSON (server keeps the hashes)
     * @param  answersJson    JSON array of user-submitted answer hashes (uppercase hex)
     * @param  attemptNumber  Current attempt (1-based)
     * @return VerificationResult
     */
    @AuraEnabled
    public static VerificationResult verifySecurityQuestions(
            String payloadJson, String answersJson, Integer attemptNumber) {

        ChallengeData data = (ChallengeData) JSON.deserialize(payloadJson, ChallengeData.class);
        List<String> submittedHashes = (List<String>) JSON.deserialize(answersJson, List<String>.class);

        VerificationResult result = new VerificationResult();
        result.attemptsRemaining = MAX_ATTEMPTS - attemptNumber;

        // Compare each answer hash
        Boolean allMatch = true;
        if (data.security_question == null ||
            submittedHashes == null ||
            data.security_question.size() != submittedHashes.size()) {
            allMatch = false;
        } else {
            for (Integer i = 0; i < data.security_question.size(); i++) {
                String expected = data.security_question[i].answer;
                String submitted = submittedHashes[i];
                if (expected == null || submitted == null ||
                    !expected.toUpperCase().equals(submitted.toUpperCase())) {
                    allMatch = false;
                    break;
                }
            }
        }

        if (allMatch) {
            result.passed = true;
            result.message = 'Identity verified. Records merged.';
            result.nextRoute = (data.application_completed == 1) ? 'dashboard' : 'resume';
        } else {
            result.passed = false;
            if (result.attemptsRemaining > 0) {
                result.message = 'Information did not match. ' +
                    result.attemptsRemaining + ' attempt' +
                    (result.attemptsRemaining == 1 ? '' : 's') + ' remaining.';
            } else {
                result.message = 'Maximum attempts reached.';
                result.nextRoute = 'escalate';
            }
        }

        return result;
    }

    /**
     * Verify personal identifiers (Option 2):
     * dob, phone, last_name, city_birth
     *
     * @param  payloadJson    Original ChallengeData JSON
     * @param  dob            User-submitted date of birth
     * @param  phone          User-submitted phone
     * @param  lastName       User-submitted last name
     * @param  cityBirth      User-submitted city of birth
     * @param  attemptNumber  Current attempt (1-based)
     * @return VerificationResult
     */
    @AuraEnabled
    public static VerificationResult verifyPersonalIdentifiers(
            String payloadJson, String dob, String phone,
            String lastName, String cityBirth, Integer attemptNumber) {

        ChallengeData data = (ChallengeData) JSON.deserialize(payloadJson, ChallengeData.class);

        VerificationResult result = new VerificationResult();
        result.attemptsRemaining = MAX_ATTEMPTS - attemptNumber;

        Boolean match = safeEquals(data.dob, dob) &&
                        safeEquals(normalizePhone(data.phone), normalizePhone(phone)) &&
                        safeEqualsIgnoreCase(data.last_name, lastName) &&
                        safeEqualsIgnoreCase(data.city_birth, cityBirth);

        if (match) {
            result.passed = true;
            result.message = 'Identity verified. Records merged.';
            result.nextRoute = (data.application_completed == 1) ? 'dashboard' : 'resume';
        } else {
            result.passed = false;
            if (result.attemptsRemaining > 0) {
                result.message = 'Information did not match. ' +
                    result.attemptsRemaining + ' attempt' +
                    (result.attemptsRemaining == 1 ? '' : 's') + ' remaining.';
            } else {
                result.message = 'Maximum attempts reached.';
                result.nextRoute = 'escalate';
            }
        }

        return result;
    }

    /**
     * Verify service number (Option 3).
     */
    @AuraEnabled
    public static VerificationResult verifyServiceNumber(
            String payloadJson, String serviceNb, Integer attemptNumber) {

        ChallengeData data = (ChallengeData) JSON.deserialize(payloadJson, ChallengeData.class);

        VerificationResult result = new VerificationResult();
        result.attemptsRemaining = MAX_ATTEMPTS - attemptNumber;

        Boolean match = safeEqualsIgnoreCase(data.service_nb, serviceNb);

        if (match) {
            result.passed = true;
            result.message = 'Identity verified. Records merged.';
            result.nextRoute = (data.application_completed == 1) ? 'dashboard' : 'resume';
        } else {
            result.passed = false;
            if (result.attemptsRemaining > 0) {
                result.message = 'Information did not match. ' +
                    result.attemptsRemaining + ' attempt' +
                    (result.attemptsRemaining == 1 ? '' : 's') + ' remaining.';
            } else {
                result.message = 'Maximum attempts reached.';
                result.nextRoute = 'escalate';
            }
        }

        return result;
    }

    /**
     * Verify applicant data (Option 4):
     * given_name and alpha_nb
     */
    @AuraEnabled
    public static VerificationResult verifyApplicantData(
            String payloadJson, String givenName, String alphaNb, Integer attemptNumber) {

        ChallengeData data = (ChallengeData) JSON.deserialize(payloadJson, ChallengeData.class);

        VerificationResult result = new VerificationResult();
        result.attemptsRemaining = MAX_ATTEMPTS - attemptNumber;

        String expectedGivenName = '';
        String expectedAlphaNb = '';
        if (data.Applicant_data != null && data.Applicant_data.personal_info != null) {
            expectedGivenName = data.Applicant_data.personal_info.pers_GivenName;
            expectedAlphaNb = data.Applicant_data.personal_info.alpha_nb;
        }

        Boolean match = safeEqualsIgnoreCase(expectedGivenName, givenName) &&
                        safeEqualsIgnoreCase(expectedAlphaNb, alphaNb);

        if (match) {
            result.passed = true;
            result.message = 'Identity verified. Records merged.';
            result.nextRoute = (data.application_completed == 1) ? 'dashboard' : 'resume';
        } else {
            result.passed = false;
            if (result.attemptsRemaining > 0) {
                result.message = 'Information did not match. ' +
                    result.attemptsRemaining + ' attempt' +
                    (result.attemptsRemaining == 1 ? '' : 's') + ' remaining.';
            } else {
                result.message = 'Maximum attempts reached.';
                result.nextRoute = 'escalate';
            }
        }

        return result;
    }

    /* ============================================================
     * Utility helpers
     * ============================================================ */

    private static Boolean safeEquals(String a, String b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        return a.trim().equals(b.trim());
    }

    private static Boolean safeEqualsIgnoreCase(String a, String b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        return a.trim().equalsIgnoreCase(b.trim());
    }

    /**
     * Strip non-digit characters from a phone number for comparison.
     */
    private static String normalizePhone(String phone) {
        if (phone == null) return null;
        return phone.replaceAll('[^0-9]', '');
    }
}
