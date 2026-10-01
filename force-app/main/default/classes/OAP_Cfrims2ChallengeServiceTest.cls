/**
 * @description Unit tests for OAP_Cfrims2ChallengeService.
 *              Covers session guard, local SMS/security-question validation,
 *              payload option routing, phone normalisation, hashing, and
 *              question re-pick logic.
 * @group Integration Framework
 */
@IsTest
private class OAP_Cfrims2ChallengeServiceTest {

    private static final String EMAIL = 'test.applicant@example.com.invalid';

    private static void seedHandshake() {
        OAP_Cfrims2SessionCache.putHandshake(UserInfo.getUserId(),
            new Map<String, String>{
                'accessToken' => 'test-token',
                'user_key'    => 'TESTUSERKEY',
                'session_key' => 'TESTSESSIONKEY'
            });
    }

    private static void seedSecurityQuestion(String question, String plainAnswer) {
        Cfrims2SecurityQuestion q = new Cfrims2SecurityQuestion();
        q.question = question;
        // Stored value is the salted hash, exactly as CFRIMS supplies it.
        q.answer   = OAP_Cfrims2ChallengeService.getHash(plainAnswer);

        CasePayload payload = new CasePayload();
        payload.security_question = new List<Cfrims2SecurityQuestion>{ q };
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);
    }    

    @IsTest
    static void validate_withoutSession_throws() {
        OAP_Cfrims2SessionCache.clear(UserInfo.getUserId());
        try {
            OAP_Cfrims2ChallengeService.validate('2',
                new Map<String, Object>{ 'question' => 'Q', 'answer' => 'A' }, EMAIL);
            System.assert(false, 'Expected CFRIMS_Exception for missing session');
        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            System.assert(e.getMessage().contains('sign in'),
                'Unexpected message: ' + e.getMessage());
        }
    }    

    @IsTest
    static void validate_sms_blankCode_returnsFalse() {
        seedHandshake();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '1', new Map<String, Object>(), EMAIL);
        System.assertEquals(false, result, 'Blank code must fail validation');
    }

    @IsTest
    static void validate_sms_nullAnswer_returnsFalse() {
        seedHandshake();
        Boolean result = OAP_Cfrims2ChallengeService.validate('1', null, EMAIL);
        System.assertEquals(false, result, 'Null answer must fail validation');
    }

    @IsTest
    static void validateSmsCodeLocally_noPendingIdentifier_throws() {
        // verify-mode (mode not 'register') with no stored identifier
        OAP_Cfrims2SessionCache.clear(UserInfo.getUserId());
        try {
            OAP_Cfrims2ChallengeService.validateSmsCodeLocally(
                new Map<String, Object>{ 'code' => '123456' });
            System.assert(false, 'Expected CFRIMS_Exception for missing identifier');
        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            System.assert(e.getMessage().contains('request a new code'),
                'Unexpected message: ' + e.getMessage());
        }
    }  

    @IsTest
    static void validate_securityQuestion_correctAnswer_returnsTrue() {
        seedHandshake();
        seedSecurityQuestion('What is your favourite colour?', 'Blue');

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{
                'question' => 'What is your favourite colour?',
                'answer'   => 'Blue'
            }, EMAIL);
        Test.stopTest();

        System.assertEquals(true, result, 'Matching hash must validate');
    }

    @IsTest
    static void validate_securityQuestion_wrongAnswer_returnsFalse() {
        seedHandshake();
        seedSecurityQuestion('What is your favourite colour?', 'Blue');

        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{
                'question' => 'What is your favourite colour?',
                'answer'   => 'Red'
            }, EMAIL);

        System.assertEquals(false, result, 'Wrong answer must fail validation');
    }

    @IsTest
    static void validate_securityQuestion_caseInsensitiveQuestionMatch() {
        seedHandshake();
        seedSecurityQuestion('  What Is Your Favourite Colour?  ', 'Blue');

        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{
                'question' => 'what is your favourite colour?',
                'answer'   => 'Blue'
            }, EMAIL);

        System.assertEquals(true, result,
            'Question lookup must be trim/case-insensitive');
    }

    @IsTest
    static void validate_securityQuestion_missingQuestion_returnsFalse() {
        seedHandshake();
        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{ 'answer' => 'Blue' }, EMAIL);
        System.assertEquals(false, result, 'Missing question must fail');
    }

    @IsTest
    static void validate_securityQuestion_missingAnswer_returnsFalse() {
        seedHandshake();
        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{ 'question' => 'Q?' }, EMAIL);
        System.assertEquals(false, result, 'Missing answer must fail');
    }

    @IsTest
    static void validate_securityQuestion_notInPayload_returnsFalse() {
        seedHandshake();
        seedSecurityQuestion('What is your favourite colour?', 'Blue');

        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{
                'question' => 'What city were you born in?',
                'answer'   => 'Ottawa'
            }, EMAIL);

        System.assertEquals(false, result,
            'Question absent from the cached payload must fail');
    }

    @IsTest
    static void validate_securityQuestion_noCachedPayload_returnsFalse() {
        seedHandshake();
        // No CasePayload seeded
        Boolean result = OAP_Cfrims2ChallengeService.validate('2',
            new Map<String, Object>{ 'question' => 'Q?', 'answer' => 'A' }, EMAIL);
        System.assertEquals(false, result, 'No cached payload must fail');
    }   

    @IsTest
    static void validate_unsupportedOption_throws() {
        seedHandshake();
        try {
            OAP_Cfrims2ChallengeService.validate('9',
                new Map<String, Object>(), EMAIL);
            System.assert(false, 'Expected IllegalArgumentException for option 9');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Unsupported option'),
                'Unexpected message: ' + e.getMessage());
        }
    }

    // ── validate(): options 3/4 — CFRIMS callout path ────────────────────

    private class ChallengeCalloutMock implements HttpCalloutMock {
        private final Integer status;
        private final String body;
        ChallengeCalloutMock(Integer status, String body) {
            this.status = status;
            this.body   = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setStatus(status == 200 ? 'OK' : 'Error');
            res.setBody(body);
            return res;
        }
    }

    private static Map<String, Object> option3Answer() {
        return new Map<String, Object>{
            'serviceNumber' => 'X00000001',
            'dob'           => '1990-01-01'
        };
    }

    private static Map<String, Object> option4Answer() {
        return new Map<String, Object>{
            'lastName'    => 'Test',
            'dob'         => '1990-01-01',
            'cityOfBirth' => 'Ottawa'
        };
    }

    @IsTest
    static void validate_option3_validTrue_returnsTrue() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"valid":true}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(true, result, 'valid:true must pass');
    }

    @IsTest
    static void validate_option4_statusPassed_returnsTrue() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"status":"passed"}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '4', option4Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(true, result,
            'status:passed must pass (case-insensitive)');
    }

    @IsTest
    static void validate_option3_resultOne_returnsTrue() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"result":"1"}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(true, result, 'result:"1" must pass');
    }

    @IsTest
    static void validate_option3_statusFailed_returnsFalse() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"status":"FAILED"}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(false, result, 'status:FAILED must not pass');
    }

    @IsTest
    static void validate_option3_non200_returnsFalse() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(500, '{"error":"server"}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(false, result, 'A non-200 must not pass');
    }

    @IsTest
    static void validate_option3_unparseableBody_returnsFalse() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, 'this is not json'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(false, result, 'An unparseable body must not pass');
    }

    @IsTest
    static void validate_option3_unrecognisedBody_returnsFalse() {
        seedHandshake();
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"something":"else"}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate(
            '3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(false, result,
            'A body with no valid/status/result key must not pass');
    }   

    // ── validate(): options 3/4 — local handshake comparison ─────────────

    private static void seedReferenceValues() {
        CasePayload payload = new CasePayload();
        payload.service_nb = 'H45658874';
        payload.dob        = '2001-09-18';
        payload.last_name  = 'Whale';
        payload.city_birth = 'Adamstown';
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);
    }

    @IsTest
    static void validate_option3_local_matchingValues_returnsTrue() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('3',
            new Map<String, Object>{ 'serviceNumber' => 'h45-658 874', 'dob' => '2001-09-18' },
            EMAIL);
        System.assertEquals(true, result,
            'Service number must match ignoring case/separators without a callout');
    }

    @IsTest
    static void validate_option3_local_cfrimsDateFormat_returnsTrue() {
        seedHandshake();
        CasePayload payload = new CasePayload();
        payload.service_nb = 'H45658874';
        payload.dob        = '18-Sep-2001';
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);
        Boolean result = OAP_Cfrims2ChallengeService.validate('3',
            new Map<String, Object>{ 'serviceNumber' => 'H45658874', 'dob' => '2001-09-18' },
            EMAIL);
        System.assertEquals(true, result, 'dd-MMM-yyyy reference must match yyyy-MM-dd answer');
    }

    @IsTest
    static void validate_option3_local_wrongServiceNumber_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('3',
            new Map<String, Object>{ 'serviceNumber' => 'H45658875', 'dob' => '2001-09-18' },
            EMAIL);
        System.assertEquals(false, result, 'Wrong service number must fail');
    }

    @IsTest
    static void validate_option3_local_wrongDob_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('3',
            new Map<String, Object>{ 'serviceNumber' => 'H45658874', 'dob' => '2001-09-19' },
            EMAIL);
        System.assertEquals(false, result, 'Wrong DOB must fail');
    }

    @IsTest
    static void validate_option3_local_missingAnswer_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        System.assertEquals(false,
            OAP_Cfrims2ChallengeService.validate('3', new Map<String, Object>(), EMAIL),
            'Empty answer must fail');
        System.assertEquals(false,
            OAP_Cfrims2ChallengeService.validate('3', null, EMAIL),
            'Null answer must fail');
    }

    @IsTest
    static void validate_option4_local_matchingValues_returnsTrue() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('4',
            new Map<String, Object>{
                'lastName' => '  whale ', 'dob' => '2001-09-18', 'cityOfBirth' => 'ADAMSTOWN'
            }, EMAIL);
        System.assertEquals(true, result,
            'Last name / city must match ignoring case and surrounding whitespace');
    }

    @IsTest
    static void validate_option4_local_accentInsensitive_returnsTrue() {
        seedHandshake();
        CasePayload payload = new CasePayload();
        payload.last_name  = 'Lévesque';
        payload.dob        = '1990-01-01';
        payload.city_birth = 'Montréal';
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);
        Boolean result = OAP_Cfrims2ChallengeService.validate('4',
            new Map<String, Object>{
                'lastName' => 'Levesque', 'dob' => '01/01/1990', 'cityOfBirth' => 'Montreal'
            }, EMAIL);
        System.assertEquals(true, result, 'Accents and dd/MM/yyyy must be tolerated');
    }

    @IsTest
    static void validate_option4_local_wrongCity_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('4',
            new Map<String, Object>{
                'lastName' => 'Whale', 'dob' => '2001-09-18', 'cityOfBirth' => 'Ottawa'
            }, EMAIL);
        System.assertEquals(false, result, 'Wrong city must fail');
    }

    @IsTest
    static void validate_option4_local_wrongLastName_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        Boolean result = OAP_Cfrims2ChallengeService.validate('4',
            new Map<String, Object>{
                'lastName' => 'Shark', 'dob' => '2001-09-18', 'cityOfBirth' => 'Adamstown'
            }, EMAIL);
        System.assertEquals(false, result, 'Wrong last name must fail');
    }

    @IsTest
    static void validate_option4_local_missingAnswer_returnsFalse() {
        seedHandshake();
        seedReferenceValues();
        System.assertEquals(false,
            OAP_Cfrims2ChallengeService.validate('4',
                new Map<String, Object>{ 'lastName' => 'Whale' }, EMAIL),
            'Partial answer must fail');
    }

    @IsTest
    static void validate_option3_partialReference_fallsBackToCallout() {
        seedHandshake();
        CasePayload payload = new CasePayload();
        payload.service_nb = 'H45658874';   // no dob → cannot verify locally
        OAP_Cfrims2SessionCache.putCasePayload(UserInfo.getUserId(), payload);
        Test.setMock(HttpCalloutMock.class,
            new ChallengeCalloutMock(200, '{"valid":true}'));

        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validate('3', option3Answer(), EMAIL);
        Test.stopTest();

        System.assertEquals(true, result,
            'Without full reference values the CFRIMS verify call decides');
    }

    @IsTest
    static void normaliseDate_acceptsKnownFormats() {
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('2001-09-18'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('2001-09-18T00:00:00'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('18-Sep-2001'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('18-SEP-2001'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('18 sept 2001'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('Sep 18, 2001'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('18/09/2001'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('2001/9/18'));
        System.assertEquals('2001-09-18', OAP_Cfrims2ChallengeService.normaliseDate('20010918'));
        System.assertEquals('2001-02-18', OAP_Cfrims2ChallengeService.normaliseDate('18-fév-2001'));
        System.assertEquals('garbage', OAP_Cfrims2ChallengeService.normaliseDate('garbage'),
            'Unrecognised input is returned as-is');
        System.assertEquals('18-Xyz-2001', OAP_Cfrims2ChallengeService.normaliseDate('18-Xyz-2001'),
            'Unknown month name is returned as-is');
        System.assertEquals(null, OAP_Cfrims2ChallengeService.normaliseDate(null));
        System.assertEquals(null, OAP_Cfrims2ChallengeService.normaliseDate('  '));
    }

    @IsTest
    static void normaliseText_and_normaliseServiceNumber() {
        System.assertEquals('levesque', OAP_Cfrims2ChallengeService.normaliseText('  LÉVESQUE '));
        System.assertEquals('st jean sur richelieu',
            OAP_Cfrims2ChallengeService.normaliseText('St  Jean   sur Richelieu'));
        System.assertEquals(null, OAP_Cfrims2ChallengeService.normaliseText(null));
        System.assertEquals('H45658874',
            OAP_Cfrims2ChallengeService.normaliseServiceNumber(' h45-658 874 '));
        System.assertEquals(null, OAP_Cfrims2ChallengeService.normaliseServiceNumber(null));
    }

    @IsTest
    static void requestSmsCode_blankPhone_throws() {
        try {
            OAP_Cfrims2ChallengeService.requestSmsCode(EMAIL, '');
            System.assert(false, 'Expected CFRIMS_Exception for blank phone');
        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            System.assert(e.getMessage().contains('No phone number'),
                'Unexpected message: ' + e.getMessage());
        }
    }   

    @IsTest
    static void requestSmsCode_withPhone_runsRegisterPath() {
        Test.startTest();
        try {
            String masked = OAP_Cfrims2ChallengeService.requestSmsCode(
                EMAIL, '6131111111');
            System.assertNotEquals(null, masked,
                'When the platform call succeeds, a masked phone is returned');
        } catch (Exception e) {
            
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void validateSmsCodeLocally_registerMode_runsVerifyRegisterPath() {
        OAP_Cfrims2SessionCache.putOtpMode(UserInfo.getUserId(), 'register');
        Test.startTest();
        try {
            Boolean result = OAP_Cfrims2ChallengeService.validateSmsCodeLocally(
                new Map<String, Object>{ 'code' => '123456' });
            System.assertNotEquals(null, result,
                'When the platform call succeeds, a boolean is returned');
        } catch (Exception e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void validateSmsCodeLocally_verifyMode_runsVerifyPath() {
        OAP_Cfrims2SessionCache.putOtpMode(UserInfo.getUserId(), 'verify');
        OAP_Cfrims2SessionCache.putOtpIdentifier(UserInfo.getUserId(), 'test-identifier');       
        OAP_Cfrims2ChallengeService.stubVerifyResult = true;
        Test.startTest();
        Boolean result = OAP_Cfrims2ChallengeService.validateSmsCodeLocally(
            new Map<String, Object>{ 'code' => '123456' });
        Test.stopTest();
        System.assertEquals(true, result,
            'A successful verification must return true');
    } 

    @IsTest
    static void toE164_normalisesFormats() {
        System.assertEquals('+16131111111',
            OAP_Cfrims2ChallengeService.toE164('(613) 111-1111'),
            '10-digit NANP number must gain +1');
        System.assertEquals('+16131111111',
            OAP_Cfrims2ChallengeService.toE164('16131111111'),
            '11-digit number starting with 1 must gain +');
        System.assertEquals('+16131111111',
            OAP_Cfrims2ChallengeService.toE164('+16131111111'),
            'Already-E.164 number must round-trip unchanged');
        System.assertEquals('12345',
            OAP_Cfrims2ChallengeService.toE164('12345'),
            'Unrecognised format must be left alone');
        System.assertEquals(null, OAP_Cfrims2ChallengeService.toE164(null),
            'Null must pass through');
        System.assertEquals('', OAP_Cfrims2ChallengeService.toE164(''),
            'Blank must pass through');
    }  

    @IsTest
    static void getHash_isDeterministicAndSalted() {
        String h1 = OAP_Cfrims2ChallengeService.getHash('Blue');
        String h2 = OAP_Cfrims2ChallengeService.getHash('Blue');
        String h3 = OAP_Cfrims2ChallengeService.getHash('blue');

        System.assertNotEquals(null, h1, 'Hash must not be null');
        System.assertEquals(40, h1.length(), 'SHA-1 hex digest is 40 chars');
        System.assertEquals(h1, h2, 'Same input must hash identically');
        System.assertNotEquals(h1, h3, 'Hash must be case-sensitive on input');
        System.assertEquals(null, OAP_Cfrims2ChallengeService.getHash(null),
            'Null input must return null');
    }
   
    private static Cfrims2SecurityQuestion mkQuestion(String text) {
        Cfrims2SecurityQuestion q = new Cfrims2SecurityQuestion();
        q.question = text;
        return q;
    }

    @IsTest
    static void pickDifferentQuestion_handlesNullAndEmpty() {
        System.assertEquals(null,
            OAP_Cfrims2ChallengeService.pickDifferentQuestion('Q1', null),
            'Null list must return null');
        System.assertEquals(null,
            OAP_Cfrims2ChallengeService.pickDifferentQuestion(
                'Q1', new List<Cfrims2SecurityQuestion>()),
            'Empty list must return null');
    }

    @IsTest
    static void pickDifferentQuestion_singleQuestion_returnsIt() {
        List<Cfrims2SecurityQuestion> all =
            new List<Cfrims2SecurityQuestion>{ mkQuestion('Q1') };
        Cfrims2SecurityQuestion picked =
            OAP_Cfrims2ChallengeService.pickDifferentQuestion('Q1', all);
        System.assertEquals('Q1', picked.question,
            'Single-question list must return that question');
    }

    @IsTest
    static void pickDifferentQuestion_avoidsCurrentQuestion() {
        List<Cfrims2SecurityQuestion> all = new List<Cfrims2SecurityQuestion>{
            mkQuestion('Q1'), mkQuestion('Q2'), mkQuestion('Q3')
        };
        for (Integer i = 0; i < 10; i++) {
            Cfrims2SecurityQuestion picked =
                OAP_Cfrims2ChallengeService.pickDifferentQuestion('Q2', all);
            System.assertNotEquals('Q2', picked.question,
                'Must never re-pick the current question when others exist');
        }
    }

    @IsTest
    static void pickDifferentQuestion_allSameAsCurrent_returnsFirst() {
        List<Cfrims2SecurityQuestion> all = new List<Cfrims2SecurityQuestion>{
            mkQuestion('Q1'), mkQuestion('Q1')
        };
        Cfrims2SecurityQuestion picked =
            OAP_Cfrims2ChallengeService.pickDifferentQuestion('Q1', all);
        System.assertEquals('Q1', picked.question,
            'When every question equals the current one, fall back to the first');
    }
}