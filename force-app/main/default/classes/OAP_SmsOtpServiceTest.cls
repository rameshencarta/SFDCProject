/**
 * Tests for OAP_SmsOtpService.
 *
 * The Google send is mocked: OAP_CustomOTPDeliveryHandler.sendOtp posts to the
 * SMSGoogleNamedCred named credential, so every test that sends must call
 * Test.setMock first. The generated code is never returned by the service, so
 * the tests inject a known one through testCodeOverride and move the clock with
 * testClockOffsetMillis rather than waiting out the TTL or the resend cooldown.
 *
 * Prerequisite: Portal_Config__mdt.Configs.GoogleSMSFromNumber__c must be
 * populated — custom metadata is visible in tests but cannot be inserted by
 * them, and sendOtp rejects the request without a sender number.
 */
@IsTest
private class OAP_SmsOtpServiceTest {

    private static final String PHONE = '+16478602992';
    private static final String CODE  = '123456';

    // Apex forbids static members on inner classes, so the captured body lives here.
    private static String lastRequestBody;

    private class GoogleSmsMock implements HttpCalloutMock {
        private Integer statusCode;

        private GoogleSmsMock(Integer statusCode) {
            this.statusCode = statusCode;
        }

        public HttpResponse respond(HttpRequest request) {
            lastRequestBody = request.getBody();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"request_id":"test-request-id"}');
            return response;
        }
    }

    private static String sendWithMock(Integer statusCode) {
        Portal_Config__mdt config = Portal_Config__mdt.getInstance('Configs');
        Assert.isTrue(
            config != null && String.isNotBlank(config.GoogleSMSFromNumber__c),
            'Portal_Config__mdt.Configs.GoogleSMSFromNumber__c must be populated: '
            + 'sendOtp rejects a request with no sender number, and custom '
            + 'metadata cannot be inserted by a test');

        Test.setMock(HttpCalloutMock.class, new GoogleSmsMock(statusCode));
        OAP_SmsOtpService.testCodeOverride = CODE;
        return OAP_SmsOtpService.sendCode(PHONE);
    }

    private static void assertMaskedForDisplay(String masked) {
        Assert.isNotNull(masked, 'sendCode must return the masked number');
        Assert.isTrue(masked.endsWith('2992'),
            'The applicant needs the last four digits to recognise the number, got: '
            + masked);
        Assert.isFalse(masked.contains('647') || masked.contains(CODE),
            'Neither the full number nor the code may reach the UI, got: ' + masked);
    }

    @IsTest
    static void sendCodeDeliversTheCodeAndReturnsMaskedPhone() {
        Test.startTest();
        String masked = sendWithMock(200);
        Test.stopTest();

        // Asserted by contract, not by mask format (maskPhone has its own test):
        // the return value is display-only, so it must identify the number by its
        // last four digits and leak neither the rest of it nor the code.
        assertMaskedForDisplay(masked);
        Assert.isTrue(lastRequestBody != null && lastRequestBody.contains(CODE),
            'The code must survive into the SMS body — sendOtp reduces a message '
            + 'containing brackets to substringBetween("(", ")"), which would '
            + 'strip it out');
    }

    @IsTest
    static void verifyCodeAcceptsTheCodeThatWasSentOnlyOnce() {
        sendWithMock(200);

        Test.startTest();
        Assert.isTrue(OAP_SmsOtpService.verifyCode(CODE));

        try {
            OAP_SmsOtpService.verifyCode(CODE);
            Assert.fail('A verified code must not be reusable');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('No code is outstanding'),
                'Unexpected message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void verifyCodeRejectsAWrongCodeWithoutConsumingTheChallenge() {
        sendWithMock(200);

        Test.startTest();
        Assert.isFalse(OAP_SmsOtpService.verifyCode('000000'));
        Assert.isFalse(OAP_SmsOtpService.verifyCode(null));
        Assert.isTrue(OAP_SmsOtpService.verifyCode(CODE),
            'A wrong attempt must not invalidate the outstanding code');
        Test.stopTest();
    }

    @IsTest
    static void verifyCodeStopsAfterFiveWrongAttempts() {
        sendWithMock(200);

        Test.startTest();
        for (Integer i = 0; i < 5; i++) {
            Assert.isFalse(OAP_SmsOtpService.verifyCode('000000'));
        }
        try {
            OAP_SmsOtpService.verifyCode(CODE);
            Assert.fail('The sixth attempt must be refused, even with the right code');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('Too many incorrect codes'),
                'Unexpected message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void verifyCodeRefusesAnExpiredCode() {
        sendWithMock(200);

        Test.startTest();
        OAP_SmsOtpService.testClockOffsetMillis = 301 * 1000L;  // TTL is 5 minutes
        try {
            OAP_SmsOtpService.verifyCode(CODE);
            Assert.fail('An expired code must not verify');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('expired'),
                'Unexpected message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void verifyCodeThrowsWhenNothingWasSent() {
        Test.startTest();
        try {
            OAP_SmsOtpService.verifyCode(CODE);
            Assert.fail('There is no challenge to verify against');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('No code is outstanding'),
                'Unexpected message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void sendCodeThrottlesAnImmediateResendButAllowsALaterOne() {
        sendWithMock(200);

        Test.startTest();
        try {
            OAP_SmsOtpService.sendCode(PHONE);
            Assert.fail('An immediate resend must be throttled');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('wait'),
                'Unexpected message: ' + e.getMessage());
        }

        OAP_SmsOtpService.testClockOffsetMillis = 31 * 1000L;  // cooldown is 30s
        assertMaskedForDisplay(OAP_SmsOtpService.sendCode(PHONE));
        Test.stopTest();
    }

    @IsTest
    static void sendCodeRejectsANumberThatIsNotE164() {
        Test.startTest();
        for (String bad : new List<String>{ null, '', '6478602992', '+1 647 860 2992' }) {
            try {
                OAP_SmsOtpService.sendCode(bad);
                Assert.fail('Expected rejection of: ' + bad);
            } catch (OAP_SmsOtpService.SmsOtpException e) {
                Assert.isTrue(e.getMessage().contains('phone number on file'),
                    'Unexpected message: ' + e.getMessage());
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void sendCodeSurfacesADeliveryFailureAndStoresNoChallenge() {
        Test.startTest();
        try {
            sendWithMock(500);
            Assert.fail('A non-200 from Google must not look like a successful send');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('could not send the code'),
                'Unexpected message: ' + e.getMessage());
        }

        try {
            OAP_SmsOtpService.verifyCode(CODE);
            Assert.fail('An undelivered code must not be verifiable');
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            Assert.isTrue(e.getMessage().contains('No code is outstanding'),
                'Unexpected message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void maskPhoneKeepsOnlyTheLastFourDigits() {
        Assert.areEqual('***-***-2992', OAP_SmsOtpService.maskPhone('+1 647-860-2992'));
        Assert.areEqual('***992', OAP_SmsOtpService.maskPhone('992'));
        Assert.isNull(OAP_SmsOtpService.maskPhone('  '));
    }
}
