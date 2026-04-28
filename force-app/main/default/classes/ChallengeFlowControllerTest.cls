/**
 * @File Name        : ChallengeFlowControllerTest.cls
 * @Description      : Test class for ChallengeFlowController
 * @Author           : Devin AI
 * @Last Modified On : April 28, 2026
 **/
@isTest
private class ChallengeFlowControllerTest {

    /* ============================================================
     * Test payload that mirrors the real CFRIMS JSON structure
     * ============================================================ */
    private static String buildTestPayload(
            Integer appCompleted, Integer requireMerge,
            Integer manualMerge, Integer mergeApproved,
            Integer opt1, Integer opt2, Integer opt3, Integer opt4) {

        return '{'
            + '"application_completed":' + appCompleted + ','
            + '"require_merge":' + requireMerge + ','
            + '"manual_merge_required":' + manualMerge + ','
            + '"merge_approved":' + mergeApproved + ','
            + '"option1":' + opt1 + ','
            + '"option2":' + opt2 + ','
            + '"option3":' + opt3 + ','
            + '"option4":' + opt4 + ','
            + '"security_question":['
            +   '{"question":"mother name at birth","answer":"5C4460A19A5441BD8C4B50F00669CF16150EC906"},'
            +   '{"question":"best rap artist","answer":"1A4DE9116530E1B795C508FFCF76D8F07E4297AC"},'
            +   '{"question":"fav pet name","answer":"460EFCFC1C3102D54A93435A76FFC675D94A53B9"}'
            + '],'
            + '"service_nb":null,'
            + '"dob":"1985-05-15",'
            + '"phone":"(963)258-4123",'
            + '"last_name":"Aboap20251117t4",'
            + '"city_birth":"Ottawa",'
            + '"Applicant_data":{'
            +   '"personal_info":{'
            +     '"pers_GivenName":"Abakar",'
            +     '"pers_Surname":"Aboap20251117t4",'
            +     '"pers_DateOfBirth":"1985-05-15",'
            +     '"alpha_nb":"A844277",'
            +     '"pers_DateOfBirthCity":"Ottawa",'
            +     '"pers_DateOfBirthCountry":"CAN",'
            +     '"service_nb":null'
            +   '},'
            +   '"complete":"1"'
            + '}'
            + '}';
    }

    private static String getDefaultPayload() {
        return buildTestPayload(1, 1, 0, 0, 1, 1, 0, 1);
    }

    /* ============================================================
     * evaluateMergeDecision tests
     * ============================================================ */

    @isTest
    static void testEvaluateMergeDecision_ShowChallenge() {
        // manual_merge_required=0, require_merge=1 -> should show challenge
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.MergeDecisionResult result =
            ChallengeFlowController.evaluateMergeDecision(payload);
        Test.stopTest();

        System.assertEquals(true, result.showChallenge,
            'Should show challenge when require_merge=1 and manual_merge_required=0');
        System.assertEquals(false, result.noMergeNeeded, 'noMergeNeeded should be false');
        System.assertNotEquals(null, result.questions, 'Questions should not be null');
        System.assertEquals(3, result.questions.size(), 'Should have 3 questions');
        System.assert(result.existingRecordLabel.contains('Aboap20251117t4'),
            'Label should contain surname');
        System.assert(result.existingRecordLabel.contains('A844277'),
            'Label should contain alpha number');

        // Verify available options
        System.assert(result.availableOptions.contains(1), 'Option 1 should be available');
        System.assert(result.availableOptions.contains(2), 'Option 2 should be available');
        System.assert(!result.availableOptions.contains(3),
            'Option 3 should NOT be available (service_nb is null)');
        System.assert(result.availableOptions.contains(4), 'Option 4 should be available');
    }

    @isTest
    static void testEvaluateMergeDecision_NoMergeNeeded_AppComplete() {
        // manual_merge_required=0, require_merge=0 -> no merge, route to dashboard
        String payload = buildTestPayload(1, 0, 0, 0, 1, 1, 0, 1);

        Test.startTest();
        ChallengeFlowController.MergeDecisionResult result =
            ChallengeFlowController.evaluateMergeDecision(payload);
        Test.stopTest();

        System.assertEquals(false, result.showChallenge);
        System.assertEquals(true, result.noMergeNeeded);
        System.assertEquals('dashboard', result.directRoute);
    }

    @isTest
    static void testEvaluateMergeDecision_NoMergeNeeded_AppIncomplete() {
        // manual_merge_required=0, require_merge=0, app not complete -> resume
        String payload = buildTestPayload(0, 0, 0, 0, 1, 1, 0, 1);

        Test.startTest();
        ChallengeFlowController.MergeDecisionResult result =
            ChallengeFlowController.evaluateMergeDecision(payload);
        Test.stopTest();

        System.assertEquals(false, result.showChallenge);
        System.assertEquals(true, result.noMergeNeeded);
        System.assertEquals('resume', result.directRoute);
    }

    @isTest
    static void testEvaluateMergeDecision_ManualMerge() {
        // manual_merge_required=1, merge_approved=0 -> no merge needed
        String payload = buildTestPayload(1, 1, 1, 0, 1, 1, 0, 1);

        Test.startTest();
        ChallengeFlowController.MergeDecisionResult result =
            ChallengeFlowController.evaluateMergeDecision(payload);
        Test.stopTest();

        System.assertEquals(false, result.showChallenge);
        System.assertEquals(true, result.noMergeNeeded);
        System.assertEquals('dashboard', result.directRoute);
    }

    @isTest
    static void testEvaluateMergeDecision_BlankPayload() {
        Test.startTest();
        try {
            ChallengeFlowController.evaluateMergeDecision('');
            System.assert(false, 'Should have thrown an exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'),
                'Error message should mention required');
        }
        Test.stopTest();
    }

    @isTest
    static void testEvaluateMergeDecision_InvalidJson() {
        Test.startTest();
        try {
            ChallengeFlowController.evaluateMergeDecision('not valid json');
            System.assert(false, 'Should have thrown an exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Invalid'),
                'Error message should mention invalid');
        }
        Test.stopTest();
    }

    /* ============================================================
     * verifySecurityQuestions tests
     * ============================================================ */

    @isTest
    static void testVerifySecurityQuestions_AllCorrect() {
        String payload = getDefaultPayload();
        // These are the SHA-1 hashes stored in the test payload
        String answersJson = '["5C4460A19A5441BD8C4B50F00669CF16150EC906",'
            + '"1A4DE9116530E1B795C508FFCF76D8F07E4297AC",'
            + '"460EFCFC1C3102D54A93435A76FFC675D94A53B9"]';

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifySecurityQuestions(payload, answersJson, 1);
        Test.stopTest();

        System.assertEquals(true, result.passed, 'Should pass with correct hashes');
        System.assertEquals('dashboard', result.nextRoute,
            'Should route to dashboard (app complete)');
        System.assert(result.message.contains('verified'), 'Message should confirm verification');
    }

    @isTest
    static void testVerifySecurityQuestions_WrongAnswer_AttemptsRemaining() {
        String payload = getDefaultPayload();
        String answersJson = '["WRONG","WRONG","WRONG"]';

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifySecurityQuestions(payload, answersJson, 1);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail with wrong hashes');
        System.assertEquals(2, result.attemptsRemaining, 'Should have 2 attempts remaining');
        System.assert(result.message.contains('did not match'),
            'Message should indicate mismatch');
    }

    @isTest
    static void testVerifySecurityQuestions_MaxAttemptsReached() {
        String payload = getDefaultPayload();
        String answersJson = '["WRONG","WRONG","WRONG"]';

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifySecurityQuestions(payload, answersJson, 3);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail');
        System.assertEquals(0, result.attemptsRemaining, 'No attempts remaining');
        System.assertEquals('escalate', result.nextRoute, 'Should escalate');
        System.assert(result.message.contains('Maximum'), 'Message should mention max attempts');
    }

    @isTest
    static void testVerifySecurityQuestions_MismatchedArraySize() {
        String payload = getDefaultPayload();
        // Only 2 answers instead of 3
        String answersJson = '["5C4460A19A5441BD8C4B50F00669CF16150EC906",'
            + '"1A4DE9116530E1B795C508FFCF76D8F07E4297AC"]';

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifySecurityQuestions(payload, answersJson, 1);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail with wrong number of answers');
    }

    /* ============================================================
     * verifyPersonalIdentifiers tests
     * ============================================================ */

    @isTest
    static void testVerifyPersonalIdentifiers_AllCorrect() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyPersonalIdentifiers(
                payload, '1985-05-15', '(963)258-4123', 'Aboap20251117t4', 'Ottawa', 1);
        Test.stopTest();

        System.assertEquals(true, result.passed, 'Should pass with correct identifiers');
        System.assertEquals('dashboard', result.nextRoute);
    }

    @isTest
    static void testVerifyPersonalIdentifiers_CaseInsensitive() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyPersonalIdentifiers(
                payload, '1985-05-15', '9632584123', 'aboap20251117t4', 'ottawa', 1);
        Test.stopTest();

        System.assertEquals(true, result.passed,
            'Should pass - case insensitive and phone normalized');
    }

    @isTest
    static void testVerifyPersonalIdentifiers_WrongDob() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyPersonalIdentifiers(
                payload, '1990-01-01', '(963)258-4123', 'Aboap20251117t4', 'Ottawa', 1);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail with wrong DOB');
    }

    /* ============================================================
     * verifyServiceNumber tests
     * ============================================================ */

    @isTest
    static void testVerifyServiceNumber_NullServiceNb() {
        // service_nb is null in the payload -> should fail
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyServiceNumber(payload, 'SVC123', 1);
        Test.stopTest();

        System.assertEquals(false, result.passed,
            'Should fail when payload service_nb is null');
    }

    /* ============================================================
     * verifyApplicantData tests
     * ============================================================ */

    @isTest
    static void testVerifyApplicantData_Correct() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyApplicantData(
                payload, 'Abakar', 'A844277', 1);
        Test.stopTest();

        System.assertEquals(true, result.passed, 'Should pass with correct data');
        System.assertEquals('dashboard', result.nextRoute);
    }

    @isTest
    static void testVerifyApplicantData_CaseInsensitive() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyApplicantData(
                payload, 'abakar', 'a844277', 1);
        Test.stopTest();

        System.assertEquals(true, result.passed, 'Should pass - case insensitive');
    }

    @isTest
    static void testVerifyApplicantData_Wrong() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyApplicantData(
                payload, 'WrongName', 'WRONG', 1);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail with wrong data');
    }

    @isTest
    static void testVerifyApplicantData_MaxAttempts() {
        String payload = getDefaultPayload();

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifyApplicantData(
                payload, 'WrongName', 'WRONG', 3);
        Test.stopTest();

        System.assertEquals(false, result.passed, 'Should fail');
        System.assertEquals('escalate', result.nextRoute, 'Should escalate at max attempts');
    }

    /* ============================================================
     * Route by application_completed tests
     * ============================================================ */

    @isTest
    static void testVerifySecurityQuestions_RoutesToResume() {
        // application_completed=0 -> should route to resume
        String payload = buildTestPayload(0, 1, 0, 0, 1, 1, 0, 1);
        String answersJson = '["5C4460A19A5441BD8C4B50F00669CF16150EC906",'
            + '"1A4DE9116530E1B795C508FFCF76D8F07E4297AC",'
            + '"460EFCFC1C3102D54A93435A76FFC675D94A53B9"]';

        Test.startTest();
        ChallengeFlowController.VerificationResult result =
            ChallengeFlowController.verifySecurityQuestions(payload, answersJson, 1);
        Test.stopTest();

        System.assertEquals(true, result.passed);
        System.assertEquals('resume', result.nextRoute,
            'Should route to resume when app not complete');
    }
}
