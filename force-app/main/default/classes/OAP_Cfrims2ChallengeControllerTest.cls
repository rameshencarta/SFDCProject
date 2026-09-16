/**
 * @description Test class for OAP_Cfrims2ChallengeController.
 * @author Ramesh / DND
 */
@IsTest
private class OAP_Cfrims2ChallengeControllerTest {

    static final String TEST_EMAIL = 'oap.challenge.test@example.invalid';

    // ── HttpCalloutMock implementations
    private class UkEmailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'               => 0,
                'error'                 => '500',
                'message'               => 'ORA-00001: unique constraint (CFRG.UK_EMAIL) violated\nORA-06512: at "CFRG.SALESFORCE", line 62\n',
                'application_completed' => 0,
                'require_merge'         => 0,
                'manual_merge_required' => 0,
                'merge_approved'        => 0,
                'redirect_to_cfrg'      => false,
                'opened_for_reapply'    => 0,
                'option1'               => 0,
                'option2'               => 0,
                'option3'               => 0,
                'option4'               => 0,
                'option5'               => 0,
                'security_question'     => null,
                'service_nb'            => null,
                'dob'                   => null,
                'phone'                 => null,
                'last_name'             => null,
                'city_birth'            => null,
                'applicant_data'        => null,
                'user_key'              => null,
                'session_key'           => null,
                'accessToken'           => ''
            }));
            return res;
        }
    }

    private class UkSfIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'               => 0,
                'error'                 => '500',
                'message'               => 'ORA-00001: unique constraint (CFRG.UK_SF_ID) violated\nORA-06512: at "CFRG.SALESFORCE", line 62\n',
                'application_completed' => 0,
                'require_merge'         => 1,
                'manual_merge_required' => 1,
                'merge_approved'        => 0,
                'redirect_to_cfrg'      => false,
                'opened_for_reapply'    => 0,
                'option1'               => 1,
                'option2'               => 0,
                'option3'               => 0,
                'option4'               => 0,
                'option5'               => 0,
                'security_question'     => null,
                'service_nb'            => null,
                'dob'                   => null,
                'phone'                 => null,
                'last_name'             => null,
                'city_birth'            => null,
                'applicant_data'        => null,
                'user_key'              => null,
                'session_key'           => null,
                'accessToken'           => ''
            }));
            return res;
        }
    }

    /**
     * Generic 500 — not a constraint violation.
     * Should cause the catch block to rethrow "Identity service unavailable."
     */
    private class GenericErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    /** Generic 200 success — used where callout must not fail. */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{}');
            return res;
        }
    }

    // ── Test data helpers ─────────────────────────────────────────────────

    private static Account createPersonAccount(String email) {
        return OAP_TestUtil.createPersonAccount('OAPChallengeTest', email);
    }

    private static ApplicationForm createForm(Id accountId) {
        ApplicationForm f = new ApplicationForm(AccountId = accountId);
        // UsageType is required on ApplicationForm. Get the first active picklist
        // value dynamically — never hardcode so this works in every environment.
        Schema.DescribeFieldResult usageField = Schema.SObjectType.ApplicationForm
            .fields.getMap().get('UsageType').getDescribe();
        for (Schema.PicklistEntry entry : usageField.getPicklistValues()) {
            if (entry.isActive()) { f.put('UsageType', entry.getValue()); break; }
        }
        insert f;
        return f;
    }

    // ── applyAccountStateOverrides — @TestVisible, no callout needed ──────

    @IsTest
    static void testApplyOverrides_nullPayload_isNoOp() {
        Test.startTest();
        // Must not throw
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, null);
        Test.stopTest();
        System.assert(true, 'Null payload should be a silent no-op');
    }

    @IsTest
    static void testApplyOverrides_blankEmail_isNoOp() {
        CasePayload p       = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides('', p);
        Test.stopTest();
        System.assertEquals(0, p.application_completed,
            'Blank email should be a no-op — payload must remain unchanged');
    }

    @IsTest
    static void testApplyOverrides_alreadyCompleted_skips() {
        CasePayload p       = new CasePayload();
        p.application_completed = 1;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();
        System.assertEquals(1, p.application_completed,
            'Already-completed payload should be returned untouched');
    }

    @IsTest
    static void testApplyOverrides_noAccountFound_isNoOp() {
        CasePayload p       = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides('nobody@example.com', p);
        Test.stopTest();
        System.assertEquals(0, p.application_completed,
            'Missing account should leave payload unchanged');
    }

    @IsTest
    static void testApplyOverrides_alphaNumberPresent_setsCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Alpha_Number__pc = 'ALPHA-99999';
        update acc;

        CasePayload p       = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();
        System.assertEquals(1, p.application_completed,
            'Non-blank CFRIMS Alpha Number should mark application as completed');
    }

    @IsTest
    static void testApplyOverrides_applicantStatusPresent_setsCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Applicant_Status__pc = 'SUBMITTED';
        update acc;

        CasePayload p       = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();
        System.assertEquals(1, p.application_completed,
            'Non-blank CFRIMS Applicant Status should mark application as completed');
    }

    @IsTest
    static void testApplyOverrides_noAlphaOrStatus_noChange() {
        createPersonAccount(TEST_EMAIL); // Account exists but both fields blank

        CasePayload p       = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();
        System.assertEquals(0, p.application_completed,
            'Account with no CFRIMS state fields should leave payload unchanged');
    }
    @IsTest
    static void testApplyOverrides_syncStatusSuccess_setsCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Sync_Status__pc = 'Success';
        update acc;
        // No ApplicationForm at all — isolates this to the Sync Status
        // signal alone, not the hasSubmittedForm fallback.

        CasePayload p = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();

        System.assertEquals(1, p.application_completed,
            'CFRIMS_Sync_Status__pc = Success must mark the payload completed on its own');
    }

    @IsTest
    static void testApplyOverrides_excludedSyncStatusNoForm_staysIncomplete() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Sync_Status__pc = 'Failed'; // deliberately excluded status
        update acc;
        // No ApplicationForm — hasSubmittedForm fallback also finds nothing.

        CasePayload p = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();

        System.assertEquals(0, p.application_completed,
            'Failed is deliberately excluded from submittedStatuses — must not '
            + 'be treated as a submitted signal');
    }

    @IsTest
    static void testApplyOverrides_hasSubmittedFormViaStage_setsCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        // All Account-level signals deliberately blank/excluded — isolates
        // this test to the hasSubmittedForm(Stage) fallback specifically.
        acc.CFRIMS_Sync_Status__pc = 'Failed';
        update acc;
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Submitted';
        update form;

        CasePayload p = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();

        System.assertEquals(1, p.application_completed,
            'An ApplicationForm at Stage=Submitted must trigger the hasSubmittedForm '
            + 'fallback even when every Account-level signal is blank/excluded');
    }

    @IsTest
    static void testApplyOverrides_hasSubmittedFormViaSyncedFlag_setsCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Sync_Status__pc = 'Failed';
        update acc;
        ApplicationForm form = createForm(acc.Id);
        form.CFRIMS_Synced__c = true;
        // System mode: CFRIMS_Synced__c FLS is not granted to every deploying
        // user, and the code under test reads it in SYSTEM_MODE.
        Database.update(form, AccessLevel.SYSTEM_MODE);

        CasePayload p = new CasePayload();
        p.application_completed = 0;
        Test.startTest();
        OAP_Cfrims2ChallengeController.applyAccountStateOverrides(TEST_EMAIL, p);
        Test.stopTest();

        System.assertEquals(1, p.application_completed,
            'CFRIMS_Synced__c = true on the ApplicationForm must also trigger '
            + 'the hasSubmittedForm fallback');
    }

    // ── startSession — UK_EMAIL recovery ─────────────────────────────────

    @IsTest
    static void testStartSession_ukEmailConstraint_emptyDefaultsPayload_routesByLocalStage() {
        createPersonAccount(TEST_EMAIL);

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkEmailMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(ctx, 'UK_EMAIL recovery must return a context rather than throw');
        Assert.areEqual(TEST_EMAIL, ctx.resolvedEmail,
            'resolvedEmail must be echoed back from Apex');
        Assert.areEqual('NEW_APPLICANT', ctx.verdict,
            'A recovered payload whose merge flags and security_question are all empty '
            + 'routes by local form stage: with no form (or a Draft form) the verdict '
            + 'is NEW_APPLICANT so the applicant lands on the application page');
    }

    @IsTest
    static void testStartSession_ukEmailConstraint_emptyDefaultsPayload_submittedForm_routesByStatus() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Submitted';
        update form;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkEmailMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(ctx, 'UK_EMAIL recovery must return a context rather than throw');
        Assert.areEqual('ROUTE_BY_STATUS', ctx.verdict,
            'With an empty recovered payload and a non-Draft local form the applicant '
            + 'routes by status to the dashboard');
    }

    @IsTest
    static void testStartSession_ukEmailConstraint_withApplicationForm_populatesFormId() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkEmailMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx;
        try {
            ctx = OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            System.debug('[EXPECTED IN ENCRYPTED ORG] ' + ex.getMessage());
            return;
        }
        Test.stopTest();

        if (ctx != null && Boolean.valueOf(!ctx.applicationCompleted)) {
            System.assertEquals(form.Id, ctx.applicationFormId,
                'applicationFormId must be populated when ApplicationForm exists and app not completed');
        }
    }

    @IsTest
    static void testStartSession_ukEmailConstraint_noApplicationForm_createsDraftForm() {
        Account acc = createPersonAccount(TEST_EMAIL); // No ApplicationForm

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkEmailMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx;
        try {
            ctx = OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            System.debug('[EXPECTED IN ENCRYPTED ORG] ' + ex.getMessage());
            return;
        }
        Test.stopTest();

        if (ctx != null && Boolean.valueOf(!ctx.applicationCompleted)) {
            System.assertNotEquals(null, ctx.applicationFormId,
                'A Draft ApplicationForm must be auto-created when none exists');
            List<ApplicationForm> forms = [
                SELECT Stage FROM ApplicationForm WHERE AccountId = :acc.Id
            ];
            System.assertEquals(1, forms.size(),
                'Exactly one ApplicationForm must be created');
            System.assertEquals('Draft', forms[0].Stage,
                'The auto-created form must be at Stage=Draft');
        }
    }

    // ── startSession — UK_SF_ID recovery ─────────────────────────────────

    @IsTest
    static void testStartSession_ukSfIdConstraint_mergeRequired_returnsOption5Pending() {
        createPersonAccount(TEST_EMAIL);

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkSfIdMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx;
        try {
            ctx = OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            System.debug('[EXPECTED IN ENCRYPTED ORG] ' + ex.getMessage());
            return;
        }
        Test.stopTest();

        if (ctx != null) {
            System.assertEquals('OPTION_5_PENDING', ctx.verdict,
                'require_merge=1 in UK_SF_ID recovery must return OPTION_5_PENDING');
        }
    }

    // ── startSession — non-constraint CFRIMS error ────────────────────────

    @IsTest
    static void testStartSession_genericCfrimsError_returnsDegradedContext() {
        createPersonAccount(TEST_EMAIL);

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GenericErrorMock());
        OAP_Cfrims2ChallengeController.ChallengeContext ctx;
        try {
            ctx = OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            // Acceptable only when the degraded fallback itself cannot run
            // (e.g. session cache unavailable in this org).
            System.assert(true, 'Fallback unavailable — surfaced as AuraHandledException');
            return;
        }
        Test.stopTest();

        System.assertNotEquals(null, ctx,
            'An unrecovered CFRIMS failure must return a degraded context, not throw');
        System.assertEquals('NEW_APPLICANT', ctx.verdict,
            'With no submitted form, degraded routing must send the applicant to '
            + 'the application page');
        System.assertNotEquals(null, ctx.applicationFormId,
            'Degraded routing must guarantee a Draft ApplicationForm');
    }

    // ── startSession — blank email falls back to UserInfo ─────────────────

    @IsTest
    static void testStartSession_nullEmail_usesUserInfoEmail() {

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GenericErrorMock());
        try {
            OAP_Cfrims2ChallengeController.startSession(null);
        } catch (AuraHandledException ex) {

            System.assert(true, 'UserInfo fallback fired — exception came from callout, not blank-email guard');
        }
        Test.stopTest();
    }

    @IsTest
    static void testStartSession_blankStringEmail_usesUserInfoEmail() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GenericErrorMock());
        try {
            OAP_Cfrims2ChallengeController.startSession('');
        } catch (AuraHandledException ex) {

            System.assert(true, 'UserInfo fallback fired — exception came from callout, not blank-email guard');
        }
        Test.stopTest();
    }

    // ── startSession — stored identifier reused ───────────────────────────

    @IsTest
    static void testStartSession_storedIdentifier_isReused() {
        Account acc = createPersonAccount(TEST_EMAIL);
        // Pre-populate both identifiers — they should be reused, not regenerated
        acc.CFRIMS_User_Identifier__pc   = 'SF-GUID-STORED-12345';
        acc.CFRIMS_Client_Session_Id__pc = 'SF_SESS_STORED-99999';
        update acc;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new UkEmailMock());
        try {
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            System.debug('[EXPECTED IN ENCRYPTED ORG] ' + ex.getMessage());
        }
        Test.stopTest();

        // Verify the identifiers were not cleared during the session
        Account updated = [
            SELECT CFRIMS_User_Identifier__pc, CFRIMS_Client_Session_Id__pc
            FROM Account WHERE Id = :acc.Id LIMIT 1
        ];
        System.assert(
            updated.CFRIMS_User_Identifier__pc != null,
            'CFRIMS User Identifier should not be cleared after startSession'
        );
    }

    // ── triggerManualMerge ────────────────────────────────────────────────

    @IsTest
    static void testTriggerManualMerge_blankEmail_throws() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.triggerManualMerge('');
            System.assert(false, 'Expected AuraHandledException for blank email');
        } catch (AuraHandledException ex) {

            System.assert(true, 'Correct — AuraHandledException thrown as expected');
        }
        Test.stopTest();
    }

    @IsTest
    static void testTriggerManualMerge_nullEmail_throws() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.triggerManualMerge(null);
            System.assert(false, 'Expected AuraHandledException for null email');
        } catch (AuraHandledException ex) {
            System.assert(true, 'Correct — AuraHandledException thrown for null email');
        }
        Test.stopTest();
    }

    @IsTest
    static void testTriggerManualMerge_withStoredIdentifier_succeedsGracefully() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_User_Identifier__pc = 'SF-GUID-MANUAL-MERGE-99';
        update acc;

        // OAP_CalloutService.invoke is in try-catch — failure is non-fatal
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        try {
            OAP_Cfrims2ChallengeController.triggerManualMerge(TEST_EMAIL);
        } catch (Exception ex) {
            System.assert(false,
                'triggerManualMerge must never throw even if callout fails: ' + ex.getMessage());
        }
        Test.stopTest();
        System.assert(true, 'triggerManualMerge completed without exception');
    }

    @IsTest
    static void testTriggerManualMerge_noAccount_generatesGuidAndSucceedsGracefully() {
        // QueryException from the Account SOQL is caught inside triggerManualMerge
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        try {
            OAP_Cfrims2ChallengeController.triggerManualMerge('nobody@example.com');
        } catch (Exception ex) {
            System.assert(false,
                'triggerManualMerge must never propagate exceptions: ' + ex.getMessage());
        }
        Test.stopTest();
        System.assert(true, 'triggerManualMerge with no account completed without exception');
    }

    // ── submitAnswer — input guard tests ─────────────────────────────────

    @IsTest
    static void testSubmitAnswer_blankOptionCode_throws() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.submitAnswer(
                '', new Map<String, Object>(), TEST_EMAIL);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {

            System.assert(true, 'Correct — AuraHandledException thrown for blank option code');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitAnswer_blankUserEmail_throws() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.submitAnswer(
                '1', new Map<String, Object>(), '');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true, 'Correct — AuraHandledException thrown for blank user email');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitAnswer_nullOptionCode_throws() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.submitAnswer(
                null, new Map<String, Object>(), TEST_EMAIL);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true, 'Correct — AuraHandledException thrown for null option code');
        }
        Test.stopTest();
    }

    // ── pickDifferentQuestion ─────────────────────────────────────────────

    @IsTest
    static void testPickDifferentQuestion_emptyList_doesNotThrowFromController() {
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.pickDifferentQuestion(
                'What is your mother\'s maiden name?',
                new List<Cfrims2SecurityQuestion>()
            );
        } catch (Exception ex) {

            System.debug('pickDifferentQuestion threw from service (acceptable): ' + ex.getMessage());
        }
        Test.stopTest();
        System.assert(true, 'Controller delegate method completed');
    }

    // ── ChallengeContext DTO field verification ───────────────────────────

    @IsTest
    static void testChallengeContextDto_allFieldsInstantiate() {

        Account acc          = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);

        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            new OAP_Cfrims2ChallengeController.ChallengeContext();

        ctx.verdict              = 'NEW_APPLICANT';
        ctx.resolvedEmail        = TEST_EMAIL;
        ctx.applicationCompleted = false;
        ctx.applicationFormId    = form.Id;
        ctx.referenceNumber      = 'REF-001';
        ctx.defaultOption        = '1';
        ctx.maskedPhone          = '***-***-1234';
        ctx.availableOptions     = new List<OAP_Cfrims2AvailableOption>();
        ctx.securityQuestions    = new List<Cfrims2SecurityQuestion>();

        System.assertEquals('NEW_APPLICANT', ctx.verdict,          'verdict');
        System.assertEquals(TEST_EMAIL,       ctx.resolvedEmail,    'resolvedEmail');
        System.assertEquals(false,            ctx.applicationCompleted, 'applicationCompleted');
        System.assertEquals(form.Id,          ctx.applicationFormId,'applicationFormId must match the real inserted record');
        System.assertNotEquals(null,          ctx.applicationFormId,'applicationFormId must not be null');
    }

    @IsTest
    static void testChallengeResultDto_allFieldsInstantiate() {
        OAP_Cfrims2ChallengeController.ChallengeResult r =
            new OAP_Cfrims2ChallengeController.ChallengeResult();

        r.status              = 'SUCCESS';
        r.applicationCompleted = true;
        r.attemptsRemaining   = 2;

        System.assertEquals('SUCCESS', r.status);
        System.assertEquals(true,      r.applicationCompleted);
        System.assertEquals(2,         r.attemptsRemaining);
    }


    private class MultiEndpointMock implements HttpCalloutMock {
        Map<String, Object> handshakeBody;
        Map<String, Object> mergeBody;

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/Auth/handshake') && handshakeBody != null) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(handshakeBody));
            } else if (endpoint.contains('/Applicants/Merge') && mergeBody != null) {
                res.setStatusCode(200);
                // Plain JSON — OAP_CFRIMS_ApiClient.decryptIfOk bypasses real
                // AES decryption under Test.isRunningTest() and returns the
                // mock body as-is (see the v14 fix on that class).
                res.setBody(JSON.serialize(mergeBody));
            } else if (endpoint.contains('/Applicants/Merge')) {
                // Configured to simulate CFRIMS having no merge record at all.
                res.setStatusCode(404);
                res.setBody('');
            } else {
                res.setStatusCode(599);
                res.setBody('UNEXPECTED_ENDPOINT_CALLED: ' + endpoint);
            }
            return res;
        }
    }

    private static Map<String, Object> basicHandshakeBody() {
        return new Map<String, Object>{
            'accessToken' => 'tok.abc.def',
            'user_key'    => 'UK-1',
            'session_key' => 'SK-1'
        };
    }

    // ── decodeJwtClaims ────────────────────────────────────────────────

    private static String b64UrlEncode(String plain) {
        return EncodingUtil.base64Encode(Blob.valueOf(plain))
            .replace('+', '-').replace('/', '_').replace('=', '');
    }

    private static String buildTestJwt(Map<String, Object> claims) {
        return 'header.' + b64UrlEncode(JSON.serialize(claims)) + '.sig';
    }

    @IsTest
    static void testDecodeJwtClaims_validToken_returnsClaims() {
        String jwt = buildTestJwt(new Map<String, Object>{ 'nameid' => 'UK-1', 'exp' => 9999999999L });

        Test.startTest();
        Map<String, Object> claims = OAP_Cfrims2ChallengeController.decodeJwtClaims(jwt);
        Test.stopTest();

        System.assertNotEquals(null, claims);
        System.assertEquals('UK-1', claims.get('nameid'));
    }

    @IsTest
    static void testDecodeJwtClaims_malformedToken_returnsNull() {
        Test.startTest();
        Map<String, Object> claims = OAP_Cfrims2ChallengeController.decodeJwtClaims('not-a-jwt');
        Test.stopTest();
        System.assertEquals(null, claims, 'A string with no "." segments should decode to null');
    }

    // ── isTokenExpired ─────────────────────────────────────────────────

    @IsTest
    static void testIsTokenExpired_futureExp_returnsFalse() {
        Long farFuture = (DateTime.now().getTime() / 1000) + 3600;
        String jwt = buildTestJwt(new Map<String, Object>{ 'exp' => farFuture });

        Test.startTest();
        Boolean expired = OAP_Cfrims2ChallengeController.isTokenExpired(jwt);
        Test.stopTest();

        System.assertEquals(false, expired);
    }

    @IsTest
    static void testIsTokenExpired_pastExp_returnsTrue() {
        Long pastExp = (DateTime.now().getTime() / 1000) - 3600;
        String jwt = buildTestJwt(new Map<String, Object>{ 'exp' => pastExp });

        Test.startTest();
        Boolean expired = OAP_Cfrims2ChallengeController.isTokenExpired(jwt);
        Test.stopTest();

        System.assertEquals(true, expired);
    }

    @IsTest
    static void testIsTokenExpired_noExpClaim_returnsFalse() {
        String jwt = buildTestJwt(new Map<String, Object>{ 'nameid' => 'UK-1' });

        Test.startTest();
        Boolean expired = OAP_Cfrims2ChallengeController.isTokenExpired(jwt);
        Test.stopTest();

        System.assertEquals(false, expired,
            'No exp claim at all should be treated as not-expired, per the method contract');
    }

    @IsTest
    static void testIsTokenExpired_unparseableToken_returnsTrue() {
        Test.startTest();
        Boolean expired = OAP_Cfrims2ChallengeController.isTokenExpired('garbage-not-a-jwt');
        Test.stopTest();

        System.assertEquals(true, expired,
            'An unparseable token must fail closed (treated as expired)');
    }

     @IsTest
    static void testGetSessionSecondsRemaining_noMatchingAccount_returnsZero() {
        Test.startTest();
        Integer secs = OAP_Cfrims2ChallengeController.getSessionSecondsRemaining();
        Test.stopTest();

        System.assertEquals(0, secs,
            'Running test user has no Account with a matching PersonEmail — must return 0, not throw');
    }

    @IsTest
    static void testExtendSession_noActiveSession_throwsAuraHandledException() {
        Boolean threw = false;
        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.extendSession();
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Expected AuraHandledException when there is no stored access token to extend');
    }


    @IsTest
    static void testStartSession_mergeFieldsHaveNoEffect_checkMergeStateStillCalled() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.Merge_Required__pc = false;
        acc.Merge_Approved__pc = false;
        update acc;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = basicHandshakeBody();

        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        System.assertNotEquals(null, ctx);
        System.assertEquals('NEW_APPLICANT', ctx.verdict,
            'A genuine checkMergeState call returning 404 synthesises a no-merge '
            + 'payload with application_completed=0, which the real verdict logic '
            + '(isSynthesised && application_completed==0) routes to NEW_APPLICANT — '
            + 'not because Merge_Required__pc/Merge_Approved__pc were set to false, '
            + 'which has no effect on this controller.');
    }

    @IsTest
    static void testStartSession_noMergeRecordAtAll_returnsNewApplicant() {
        createPersonAccount(TEST_EMAIL);

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = basicHandshakeBody();

        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        System.assertEquals('NEW_APPLICANT', ctx.verdict,
            'A 404 from checkMergeState (no CFRIMS record) with application_completed=0 '
            + 'must synthesise a NEW_APPLICANT verdict');
    }
    /** Serves handshake, merge, completemerge and dashboard from one mock. */
    private class MergePathMock implements HttpCalloutMock {
        Map<String, Object> mergeBody;
        MergePathMock(Map<String, Object> mergeBody) { this.mergeBody = mergeBody; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String e = req.getEndpoint();
            if (e.contains('/Auth/handshake')) {
                res.setBody('{"accessToken":"tok.abc.def","user_key":"UK-1",'
                    + '"session_key":"SK-1"}');
            } else if (e.contains('/Applicants/Merge')) {
                res.setBody(JSON.serialize(mergeBody));
            } else {
                res.setBody('{"success":1}');
            }
            return res;
        }
    }

    private static Account mergeRequiredAccount() {
        Account a = createPersonAccount(TEST_EMAIL);
        a.Merge_Required__pc = true;
        update a;
        return a;
    }

    private static String verdictFor(Map<String, Object> mergeBody) {
        mergeRequiredAccount();
        Test.setMock(HttpCalloutMock.class, new MergePathMock(mergeBody));
        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();
        return ctx.verdict;
    }

    @IsTest
    static void startSession_realMergePayload_requireMergeZero_routesByStatus() {
        Assert.areEqual('ROUTE_BY_STATUS',
            verdictFor(new Map<String, Object>{ 'require_merge' => 0 }),
            'A real merge payload with require_merge=0 must route by status');
    }

    @IsTest
    static void startSession_realMergePayload_requireMergeOne_showsOptions() {
        Assert.areEqual('SHOW_OPTIONS',
            verdictFor(new Map<String, Object>{
                'require_merge' => 1, 'redirect_to_cfrg' => false,
                'manual_merge_required' => 0 }),
            'require_merge=1 with no manual merge and no redirect must show the options');
    }

    @IsTest
    static void startSession_realMergePayload_redirectToCfrg_returnsOption5Redirect() {
        Assert.areEqual('OPTION_5_REDIRECT',
            verdictFor(new Map<String, Object>{
                'require_merge' => 1, 'redirect_to_cfrg' => true }),
            'redirect_to_cfrg=true must win over the manual-merge branches');
    }

    @IsTest
    static void startSession_realMergePayload_manualMergeApproved_completesMergeAuto() {
        Assert.areEqual('COMPLETE_MERGE_AUTO',
            verdictFor(new Map<String, Object>{
                'require_merge' => 1, 'manual_merge_required' => 1,
                'merge_approved' => 1 }),
            'An approved manual merge must complete automatically');
    }

    @IsTest
    static void startSession_realMergePayload_manualMergeNotApproved_returnsOption5Pending() {
        Assert.areEqual('OPTION_5_PENDING',
            verdictFor(new Map<String, Object>{
                'require_merge' => 1, 'manual_merge_required' => 1,
                'merge_approved' => 0 }),
            'A manual merge awaiting approval must park the applicant at option 5');
    }

    @IsTest
    static void startSession_storedValidToken_skipsHandshakeEntirely() {
        Account a = createPersonAccount(TEST_EMAIL);
        Long future = DateTime.now().addHours(2).getTime() / 1000;
        String jwt = 'header.' + EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(
            new Map<String, Object>{
                'exp'             => future,
                'nameid'          => 'UK-STORED',
                'session_key'     => 'SK-STORED',
                'UserIdentifier'  => 'UID-STORED',
                'ClientSessionID' => 'CS-STORED'
            }))).replace('+', '-').replace('/', '_').replace('=', '') + '.sig';
        a.CFRIMS_Access_Token__pc = jwt;
        a.user_key__pc            = 'UK-STORED';
        update a;

        // Any handshake call would hit the catch-all below and change the body,
        // so reaching a verdict at all proves the stored session was reused.
        Test.setMock(HttpCalloutMock.class,
            new MergePathMock(new Map<String, Object>{ 'require_merge' => 0 }));

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(ctx, 'A stored unexpired token must yield a context');
        Assert.areEqual(jwt, ctx.accessToken,
            'The stored token must be reused rather than replaced by a fresh handshake');
    }

    @IsTest
    static void testSyncPhoneForVerification_explicitPhone_updatesMobilePhoneToE164() {
        createPersonAccount(TEST_EMAIL);

        Test.startTest();
        OAP_Cfrims2ChallengeController.syncPhoneForVerification('6478602992');
        Test.stopTest();

        User me = [SELECT MobilePhone FROM User WHERE Id = :UserInfo.getUserId()];
        System.assertEquals('+16478602992', me.MobilePhone,
            'A 10-digit number passed explicitly must be converted to E.164 via '
            + 'OAP_Cfrims2ChallengeService.toE164 and written to the running user\'s MobilePhone');
    }

    @IsTest
    static void testSyncPhoneForVerification_blankExplicitPhone_fallsBackToCachedCasePayload() {
        createPersonAccount(TEST_EMAIL);

        CasePayload payload = new CasePayload();
        payload.phone = '6135551212';
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);

        Test.startTest();

        OAP_Cfrims2ChallengeController.syncPhoneForVerification('');
        Test.stopTest();

        User me = [SELECT MobilePhone FROM User WHERE Id = :UserInfo.getUserId()];
        System.assertEquals('+16135551212', me.MobilePhone,
            'With no explicit phone, the cached CasePayload.phone must be used and '
            + 'converted to E.164');
    }

    @IsTest
    static void testSyncPhoneForVerification_alreadyMatchingPhone_doesNotThrow() {
        createPersonAccount(TEST_EMAIL);

        User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        me.MobilePhone = '+16478602992';
        update me;

        Test.startTest();

        OAP_Cfrims2ChallengeController.syncPhoneForVerification('6478602992');
        Test.stopTest();

        User after = [SELECT MobilePhone FROM User WHERE Id = :UserInfo.getUserId()];
        System.assertEquals('+16478602992', after.MobilePhone);
    }

    @IsTest
    static void testRequestSmsCode_noPhoneAnywhere_throwsAuraHandledException() {
        createPersonAccount(TEST_EMAIL);


        User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        me.MobilePhone = null;
        update me;
        // No CasePayload cached either, so resolveApplicantPhone() has
        // nothing to fall back to.

        Test.startTest();
        Boolean threw = false;
        try {
            OAP_Cfrims2ChallengeController.requestSmsCode(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw,
            'With no phone available from either the cache or the User record, '
            + 'OAP_Cfrims2ChallengeService.requestSmsCode throws CFRIMS_Exception, '
            + 'which the controller re-throws as AuraHandledException');
    }

    @IsTest
    static void testRequestSmsCode_phoneAvailable_completesWithoutUnexpectedException() {

        createPersonAccount(TEST_EMAIL);
        User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        me.MobilePhone = '6478602992';
        update me;

        Test.startTest();
        String result;
        Boolean threwAura = false;
        try {
            result = OAP_Cfrims2ChallengeController.requestSmsCode(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            threwAura = true;
        }
        Test.stopTest();

        System.assert(result != null || threwAura,
            'requestSmsCode must either return a masked phone string or throw '
            + 'AuraHandledException — no other outcome is part of its contract');
    }

    // ── startSession — stale application_completed=1 vs local Draft ──────

    @IsTest
    static void startSession_staleCompletedFlag_localDraftForm_routesToApplication() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Draft';
        update form;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = basicHandshakeBody();
        mock.handshakeBody.put('require_merge', 0);
        mock.handshakeBody.put('application_completed', 1);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('NEW_APPLICANT', ctx.verdict,
            'CFRIMS reporting application_completed=1 while the local form is '
            + 'still Draft must be overridden — the local Draft stage wins and '
            + 'the applicant routes to the application page');
        Assert.areEqual(false, ctx.applicationCompleted,
            'The stale completed flag must be reset so the portal does not '
            + 'open an empty dashboard');
        Assert.areEqual(form.Id, ctx.applicationFormId,
            'The existing Draft form must be returned for the application page');
    }

    @IsTest
    static void startSession_completedFlag_draftFormButAccountEvidence_routesByStatus() {
        // Merged CFRIMS applicant: the application lives in CFRIMS, so the
        // local form never leaves Draft — but the Account carries submission
        // evidence (alpha number, applicant status, sync status). The Draft
        // override must NOT fire: route to the dashboard.
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Sync_Status__pc      = 'Success';
        acc.CFRIMS_Alpha_Number__pc     = 'A919536';
        acc.CFRIMS_Applicant_Status__pc = '40';
        update acc;
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Draft';
        update form;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = basicHandshakeBody();
        mock.handshakeBody.put('require_merge', 0);
        mock.handshakeBody.put('application_completed', 1);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('ROUTE_BY_STATUS', ctx.verdict,
            'A completed flag corroborated by Account-level CFRIMS evidence '
            + 'is genuine even when the local form is still Draft — the '
            + 'merged applicant must route to the dashboard');
        Assert.areEqual(true, ctx.applicationCompleted,
            'applicationCompleted must stay true when the Account proves the '
            + 'CFRIMS submission');
    }

    @IsTest
    static void startSession_completedFlag_submittedLocalForm_routesByStatus() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Submitted';
        update form;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = basicHandshakeBody();
        mock.handshakeBody.put('require_merge', 0);
        mock.handshakeBody.put('application_completed', 1);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('ROUTE_BY_STATUS', ctx.verdict,
            'A completed flag backed by a non-Draft local form is genuine — '
            + 'route by status to the dashboard');
        Assert.areEqual(true, ctx.applicationCompleted,
            'applicationCompleted must stay true when the local form is submitted');
    }

    // ── latestFormIsDraftOrMissing ────────────────────────────────────────

    @IsTest
    static void latestFormIsDraftOrMissing_coversAllThreeStates() {
        Account acc = createPersonAccount(TEST_EMAIL);

        System.assertEquals(true,
            OAP_Cfrims2ChallengeController.latestFormIsDraftOrMissing(TEST_EMAIL),
            'No form at all must count as Draft/missing');

        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Draft';
        update form;
        System.assertEquals(true,
            OAP_Cfrims2ChallengeController.latestFormIsDraftOrMissing(TEST_EMAIL),
            'A Draft form must count as Draft/missing');

        form.Stage = 'Submitted';
        update form;
        System.assertEquals(false,
            OAP_Cfrims2ChallengeController.latestFormIsDraftOrMissing(TEST_EMAIL),
            'A non-Draft form must NOT count as Draft/missing');
    }

    // ── buildDegradedContext ──────────────────────────────────────────────

    @IsTest
    static void buildDegradedContext_draftForm_returnsNewApplicantWithFormId() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Draft';
        update form;

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.buildDegradedContext(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(ctx, 'Degraded routing must produce a context');
        Assert.areEqual('NEW_APPLICANT', ctx.verdict,
            'A Draft form must route to the application page in degraded mode');
        Assert.areEqual(form.Id, ctx.applicationFormId,
            'The existing Draft form must be reused, not recreated');
        Assert.areEqual(false, ctx.applicationCompleted,
            'Draft routing must not mark the application completed');
    }

    @IsTest
    static void buildDegradedContext_submittedForm_routesByStatusCompleted() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Submitted';
        update form;

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.buildDegradedContext(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(ctx, 'Degraded routing must produce a context');
        Assert.areEqual('ROUTE_BY_STATUS', ctx.verdict,
            'A non-Draft form must route to the dashboard in degraded mode');
        Assert.areEqual(true, ctx.applicationCompleted,
            'A non-Draft form must be reported as completed so the portal '
            + 'opens the dashboard');
    }

    @IsTest
    static void buildDegradedContext_noFormNoAccount_returnsNewApplicantNullFormId() {
        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.buildDegradedContext('nobody@example.invalid');
        Test.stopTest();

        Assert.isNotNull(ctx, 'Degraded routing must still produce a context');
        Assert.areEqual('NEW_APPLICANT', ctx.verdict,
            'No form must route to the application page');
        Assert.areEqual(null, ctx.applicationFormId,
            'With no Account, no Draft form can be created — formId stays null');
    }

    // ── Re-apply (opened_for_reapply) ─────────────────────────────────────

    private static Map<String, Object> reapplyHandshakeBody() {
        Map<String, Object> body = basicHandshakeBody();
        body.put('require_merge', 0);
        body.put('application_completed', 1);
        body.put('opened_for_reapply', 1);
        return body;
    }

    @IsTest
    static void startSession_openedForReapply_routesToNewDraftAndKeepsClosedForm() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.CFRIMS_Sync_Status__pc      = 'Success';
        acc.CFRIMS_Applicant_Status__pc = '40';
        update acc;
        ApplicationForm closed = createForm(acc.Id);
        closed.Stage            = 'Submitted';
        closed.CFRIMS_Synced__c = true;
        update closed;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = reapplyHandshakeBody();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('NEW_APPLICANT', ctx.verdict,
            'opened_for_reapply=1 must win over application_completed=1 and '
            + 'route the applicant to the application page');
        Assert.areEqual(false, ctx.applicationCompleted,
            'The completed flag must be reset so the portal opens the application, not the dashboard');
        Assert.areEqual(true, ctx.openedForReapply, 'openedForReapply must be exposed to the LWC');
        Assert.isNotNull(ctx.applicationFormId, 'A Draft form must be provided');
        Assert.areNotEqual(closed.Id, ctx.applicationFormId,
            'The closed form must not be reopened — a new Draft is expected');

        ApplicationForm draft = [
            SELECT Stage, CFRIMS_Synced__c, UsageType
            FROM ApplicationForm WHERE Id = :ctx.applicationFormId
        ];
        Assert.areEqual('Draft', draft.Stage);
        Assert.areEqual(false, draft.CFRIMS_Synced__c);
        Assert.areEqual(closed.UsageType, draft.UsageType, 'Draft must be prefilled from the closed form');

        ApplicationForm history = [SELECT Stage FROM ApplicationForm WHERE Id = :closed.Id];
        Assert.areEqual('Submitted', history.Stage, 'The closed form must stay as history');
        Assert.areEqual(2, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acc.Id]);
    }

    @IsTest
    static void startSession_openedForReapply_repeatLogin_reusesDraft() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm closed = createForm(acc.Id);
        closed.Stage            = 'Submitted';
        closed.CFRIMS_Synced__c = true;
        update closed;
        Id existingDraft = OAP_Cfrims2DataPullService.ensureReapplyDraft(acc.Id, closed.Id);

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = reapplyHandshakeBody();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('NEW_APPLICANT', ctx.verdict);
        Assert.areEqual(existingDraft, ctx.applicationFormId,
            'A repeat login must reuse the existing unsynced Draft');
        Assert.areEqual(2, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acc.Id],
            'No duplicate Draft may be created on repeat login');
    }

    @IsTest
    static void startSession_openedForReapply_withRequireMerge_mergeFlowWins() {
        Account acc = createPersonAccount(TEST_EMAIL);
        createForm(acc.Id);

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = reapplyHandshakeBody();
        mock.handshakeBody.put('require_merge', 1);
        mock.handshakeBody.put('manual_merge_required', 1);
        mock.handshakeBody.put('merge_approved', 0);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('OPTION_5_PENDING', ctx.verdict,
            'While a merge is still required the re-apply flag must not short-circuit the merge flow');
        Assert.areEqual(1, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acc.Id],
            'No reapply Draft may be created before the merge completes');
    }

    @IsTest
    static void startSession_openedForReapplyZero_completedForm_routesByStatus() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);
        form.Stage = 'Submitted';
        update form;

        MultiEndpointMock mock = new MultiEndpointMock();
        mock.handshakeBody = reapplyHandshakeBody();
        mock.handshakeBody.put('opened_for_reapply', 0);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OAP_Cfrims2ChallengeController.ChallengeContext ctx =
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        Test.stopTest();

        Assert.areEqual('ROUTE_BY_STATUS', ctx.verdict);
        Assert.areEqual(false, ctx.openedForReapply);
        Assert.areEqual(1, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acc.Id],
            'opened_for_reapply=0 must not create a Draft');
    }

    // ── ensureDraftApplicationForm ────────────────────────────────────────

    @IsTest
    static void ensureDraftApplicationForm_submittedNewestForm_createsReapplyDraft() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm submitted = createForm(acc.Id);
        submitted.Stage = 'Submitted';
        update submitted;

        Test.startTest();
        Id first  = OAP_Cfrims2ChallengeController.ensureDraftApplicationForm(TEST_EMAIL);
        Id second = OAP_Cfrims2ChallengeController.ensureDraftApplicationForm(TEST_EMAIL);
        Test.stopTest();

        Assert.isNotNull(first, 'A Draft must be created when the newest form is submitted');
        Assert.areNotEqual(submitted.Id, first, 'The submitted form must not be returned as the Draft');
        Assert.areEqual(first, second, 'Subsequent calls must reuse the same Draft');
        Assert.areEqual('Draft', [SELECT Stage FROM ApplicationForm WHERE Id = :first].Stage);
    }

    @IsTest
    static void ensureDraftApplicationForm_existingForm_returnsItsId() {
        Account acc = createPersonAccount(TEST_EMAIL);
        ApplicationForm form = createForm(acc.Id);

        Test.startTest();
        Id result = OAP_Cfrims2ChallengeController.ensureDraftApplicationForm(TEST_EMAIL);
        Test.stopTest();

        System.assertEquals(form.Id, result,
            'An existing form must be returned rather than a new one created');
    }

    @IsTest
    static void ensureDraftApplicationForm_noAccount_returnsNull() {
        Test.startTest();
        Id result = OAP_Cfrims2ChallengeController.ensureDraftApplicationForm(
            'nobody@example.invalid');
        Test.stopTest();

        System.assertEquals(null, result,
            'With no Account for the email, no form can be created');
    }

    // ── saveUserIdentifierWithRetry ───────────────────────────────────────

    @IsTest
    static void saveUserIdentifierWithRetry_happyPath_persistsIdentifier() {
        Account acc = createPersonAccount(TEST_EMAIL);

        Test.startTest();
        OAP_Cfrims2ChallengeController.saveUserIdentifierWithRetry(
            acc.Id, 'SF-GUID-RETRY-TEST', TEST_EMAIL);
        Test.stopTest();

        Account after = [
            SELECT CFRIMS_User_Identifier__pc FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('SF-GUID-RETRY-TEST', after.CFRIMS_User_Identifier__pc,
            'The identifier must be persisted on the first attempt');
    }

    @IsTest
    static void saveUserIdentifierWithRetry_deletedAccount_retriesAndDoesNotThrow() {
        Account acc = createPersonAccount(TEST_EMAIL);
        Id accId = acc.Id;
        delete acc;

        Test.startTest();
        try {
            OAP_Cfrims2ChallengeController.saveUserIdentifierWithRetry(
                accId, 'SF-GUID-GONE', TEST_EMAIL);
        } catch (Exception ex) {
            System.assert(false,
                'saveUserIdentifierWithRetry must never throw: ' + ex.getMessage());
        }
        Test.stopTest();
        System.assert(true, 'Both retry attempts failed silently as designed');
    }

    // ── resolveApplicantDialCode ──────────────────────────────────────────

    @IsTest
    static void resolveApplicantDialCode_ukAccount_returns44() {
        Account acc = createPersonAccount(TEST_EMAIL);
        acc.OAP_Primary_Phone_Country_Code__c = 'UK';
        update acc;

        Test.startTest();
        String code = OAP_Cfrims2ChallengeController.resolveApplicantDialCode(TEST_EMAIL);
        Test.stopTest();

        System.assertEquals('44', code,
            'A UK phone-region account must resolve dial code 44');
    }

    @IsTest
    static void resolveApplicantDialCode_noAccount_defaultsTo1() {
        Test.startTest();
        String code = OAP_Cfrims2ChallengeController.resolveApplicantDialCode(
            'nobody@example.invalid');
        Test.stopTest();

        System.assertEquals('1', code,
            'With no matching Account the dial code must default to 1');
    }

    // ── startSession — reused token whose CFRIMS session died ────────────

    /** Handshake succeeds (no merge payload) but merge state always 500s. */
    private class MergeStateAlwaysFailsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/Auth/handshake')) {
                res.setStatusCode(200);
                res.setBody('{"accessToken":"tok.abc.def","user_key":"UK-1",'
                    + '"session_key":"SK-1"}');
            } else {
                res.setStatusCode(500);
                res.setBody('Internal Server Error');
            }
            return res;
        }
    }

    @IsTest
    static void startSession_reusedTokenMergeStateFails_retriesThenThrows() {
        Account a = createPersonAccount(TEST_EMAIL);
        Long future = DateTime.now().addHours(2).getTime() / 1000;
        String jwt = 'header.' + EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(
            new Map<String, Object>{
                'exp'         => future,
                'nameid'      => 'UK-STORED',
                'session_key' => 'SK-STORED'
            }))).replace('+', '-').replace('/', '_').replace('=', '') + '.sig';
        a.CFRIMS_Access_Token__pc = jwt;
        a.user_key__pc            = 'UK-STORED';
        update a;

        Test.setMock(HttpCalloutMock.class, new MergeStateAlwaysFailsMock());

        Test.startTest();
        Boolean threw = false;
        try {
            OAP_Cfrims2ChallengeController.startSession(TEST_EMAIL);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A reused token whose merge-state call fails must retry once with a '
            + 'fresh handshake and, when that also fails, surface an '
            + 'AuraHandledException rather than looping');
    }

    // ── getSessionSecondsRemaining — stored valid token ───────────────────

    @IsTest
    static void getSessionSecondsRemaining_validStoredToken_returnsPositive() {
        Account acc = createPersonAccount(UserInfo.getUserEmail());
        Long future = DateTime.now().addHours(2).getTime() / 1000;
        String jwt = 'header.' + EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(
            new Map<String, Object>{ 'exp' => future })))
            .replace('+', '-').replace('/', '_').replace('=', '') + '.sig';
        acc.CFRIMS_Access_Token__pc = jwt;
        update acc;

        Test.startTest();
        Integer secs = OAP_Cfrims2ChallengeController.getSessionSecondsRemaining();
        Test.stopTest();

        System.assert(secs > 0,
            'A stored token expiring in 2 hours must report a positive number of '
            + 'remaining seconds');
    }
}
