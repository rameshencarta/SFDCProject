/**
 * Tests for OAP_CFRIMS_LogoutService.
 *
 * On LogoutEventTrigger: LogoutEventStream is read only and DML/EventBus.publish
 * against it throws "DML operation INSERT not allowed on LogoutEventStream", so
 * the event cannot be delivered in a test and the trigger body itself is not
 * coverable. All of its logic therefore lives in handleLogoutEvents(), which is
 * exercised directly here -- see testHandleLogoutEvents* below, including the
 * bulk case, which is what the trigger passes it.
 *
 * The CFRIMS callout depends on CFRIMS_Config__mdt. Custom metadata is visible
 * in tests, but the config record is environment-specific, so assertions on the
 * callout are made only when it resolves. Session-clearing assertions, which
 * are the point of the fix, always run.
 */
@IsTest
private class OAP_CFRIMS_LogoutServiceTest {

    private static final String TOKEN         = 'test-cfrims-access-token';
    private static final String CLIENT_ID     = 'test-client-session-id';
    private static final String USER_KEY      = 'test-user-key';
    private static final String APPLICANT_EML = 'logout.test.applicant@example.invalid';

    // -------------------------------------------------------------------
    // Callout mock
    // -------------------------------------------------------------------

    private class LogoutMock implements HttpCalloutMock {
        private final Integer statusCode;
        private LogoutMock(Integer statusCode) {
            this.statusCode = statusCode;
        }
        public HttpResponse respond(HttpRequest req) {
            calloutCount++;
            lastEndpoint = req.getEndpoint();
            lastAuthHeader = req.getHeader('Authorization');
            lastBody = req.getBody();

            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody('');
            return res;
        }
    }

    private static Integer calloutCount = 0;
    private static String lastEndpoint;
    private static String lastAuthHeader;
    private static String lastBody;

    // -------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------

    @TestSetup
    static void setup() {
        Account acct = buildApplicantAccount();
        insert acct;

        List<Contact> personContacts = [
            SELECT Id FROM Contact WHERE AccountId = :acct.Id LIMIT 1
        ];
        Assert.isFalse(personContacts.isEmpty(),
            'Person account insert did not produce a person contact');

        // Resets the DML type tracking so inserting a User alongside the
        // Account above doesn't trip the mixed-DML restriction.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert buildPortalUser(personContacts[0].Id);
        }
    }

    private static Account buildApplicantAccount() {
        Account acct = new Account(
            CFRIMS_Access_Token__pc      = TOKEN,
            CFRIMS_Client_Session_Id__pc = CLIENT_ID,
            user_key__pc                 = USER_KEY,
            PersonEmail                  = APPLICANT_EML
        );

        List<RecordType> personTypes = [
            SELECT Id FROM RecordType
            WHERE SobjectType = 'Account' AND IsPersonType = TRUE AND IsActive = TRUE
            LIMIT 1
        ];
        if (personTypes.isEmpty()) {
            // Fail loudly rather than skipping: without person accounts the
            // __pc fields are not writable and nothing here is meaningful.
            throw new IllegalArgumentException(
                'No active person account record type found; this test '
                + 'requires person accounts to be enabled.'
            );
        }
        acct.RecordTypeId = personTypes[0].Id;
        acct.FirstName = 'Logout';
        acct.LastName = 'TestApplicant';

        // A portal account's owner must hold a role, otherwise inserting the
        // community user below fails.
        List<User> roleHolders = [
            SELECT Id FROM User
            WHERE UserRoleId != NULL AND IsActive = TRUE AND Profile.UserType = 'Standard'
            LIMIT 1
        ];
        if (!roleHolders.isEmpty()) {
            acct.OwnerId = roleHolders[0].Id;
        }

        return acct;
    }

    private static User buildPortalUser(Id personContactId) {
        List<Profile> portalProfiles = [
            SELECT Id FROM Profile
            WHERE UserType IN (
                'CspLitePortal', 'CustomerSuccess', 'PowerCustomerSuccess', 'PowerPartner'
            )
            LIMIT 1
        ];
        if (portalProfiles.isEmpty()) {
            throw new IllegalArgumentException(
                'No Experience Cloud profile found; this test requires a '
                + 'portal profile to create an applicant user.'
            );
        }

        String unique = String.valueOf(Datetime.now().getTime());
        return new User(
            ProfileId         = portalProfiles[0].Id,
            ContactId         = personContactId,
            Username          = 'logout.test.' + unique + '@example.invalid',
            Email             = APPLICANT_EML,
            LastName          = 'TestApplicant',
            Alias             = 'ltest',
            TimeZoneSidKey    = 'America/New_York',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static User getPortalUser() {
        List<User> users = [
            SELECT Id FROM User
            WHERE Username LIKE 'logout.test.%@example.invalid'
            LIMIT 1
        ];
        Assert.isFalse(users.isEmpty(), 'Test setup did not create a portal user');
        return users[0];
    }

    private static Account getApplicantAccount() {
        return [
            SELECT Id, CFRIMS_Access_Token__pc, CFRIMS_Client_Session_Id__pc,
                   user_key__pc, CFRIMS_User_Identifier__pc
            FROM Account
            WHERE PersonEmail = :APPLICANT_EML
            LIMIT 1
        ];
    }

    private static Boolean configExists() {
        List<Organization> orgs = [SELECT IsSandbox FROM Organization LIMIT 1];
        Boolean isSandbox = orgs.isEmpty() ? false : orgs[0].IsSandbox;
        return CFRIMS_Config__mdt.getInstance(
            isSandbox ? 'CFRIMS_Integration_Sandbox' : 'CFRIMS_Integration_Prod'
        ) != null;
    }

    private static void assertSessionCleared(Account acct) {
        Assert.isNull(acct.CFRIMS_Access_Token__pc,
            'Access token must be cleared on logout');
        Assert.isNull(acct.CFRIMS_Client_Session_Id__pc,
            'Client session id must be cleared on logout');
        Assert.isNull(acct.user_key__pc,
            'user_key must be cleared on logout');
    }

    // -------------------------------------------------------------------
    // clearLocalSessionOnLogout
    // -------------------------------------------------------------------

    @IsTest
    static void testClearLocalSessionOnLogoutClearsFieldsAndRevokes() {
        User portalUser = getPortalUser();

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        String status;
        Test.startTest();
        System.runAs(portalUser) {
            status = OAP_CFRIMS_LogoutService.clearLocalSessionOnLogout();
        }
        Test.stopTest();

        Assert.areEqual('CLEARED', status,
            'Successful clear must report CLEARED, not a silent void');
        assertSessionCleared(getApplicantAccount());

        if (configExists()) {
            Assert.areEqual(1, calloutCount,
                'CFRIMS /Auth/logout must be called exactly once');
            Assert.isTrue(lastEndpoint.endsWith('/Auth/logout'),
                'Expected the /Auth/logout endpoint, got: ' + lastEndpoint);
            Assert.areEqual('Bearer ' + TOKEN, lastAuthHeader,
                'The token must be revoked before it is cleared from the record');
            Assert.isTrue(String.isBlank(lastBody),
                'Spec 2.3.3 requires a zero-length body');
        }
    }

    @IsTest
    static void testClearLocalSessionOnLogoutWithoutTokenStillClears() {
        User portalUser = getPortalUser();

        Account acct = getApplicantAccount();
        acct.CFRIMS_Access_Token__pc = null;
        update acct;

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        String status;
        Test.startTest();
        System.runAs(portalUser) {
            status = OAP_CFRIMS_LogoutService.clearLocalSessionOnLogout();
        }
        Test.stopTest();

        Assert.areEqual('CLEARED', status, 'Clearing must succeed without a token');
        Assert.areEqual(0, calloutCount,
            'No token means nothing to revoke, so no callout');
        assertSessionCleared(getApplicantAccount());
    }

    @IsTest
    static void testClearLocalSessionOnLogoutReportsMissingAccount() {
        // The running admin has no AccountId, standing in for any user with no
        // applicant account. The previous implementation returned void here, so
        // the caller could not tell this from success.
        Test.startTest();
        String status = OAP_CFRIMS_LogoutService.clearLocalSessionOnLogout();
        Test.stopTest();

        Assert.areEqual('NO_ACCOUNT', status,
            'A user with no applicant Account must report NO_ACCOUNT');
    }

    @IsTest
    static void testCfrimsUserIdentifierIsPreserved() {
        User portalUser = getPortalUser();

        Account acct = getApplicantAccount();
        acct.CFRIMS_User_Identifier__pc = 'SF-GUID-preserve-me';
        update acct;

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        System.runAs(portalUser) {
            OAP_CFRIMS_LogoutService.clearLocalSessionOnLogout();
        }
        Test.stopTest();

        Assert.areEqual('SF-GUID-preserve-me',
            getApplicantAccount().CFRIMS_User_Identifier__pc,
            'The stable CFRIMS identity must survive logout and be reused next login');
    }

    @IsTest
    static void testNon200LogoutResponseDoesNotBlockLogout() {
        User portalUser = getPortalUser();

        Test.setMock(HttpCalloutMock.class, new LogoutMock(500));

        String status;
        Test.startTest();
        System.runAs(portalUser) {
            status = OAP_CFRIMS_LogoutService.clearLocalSessionOnLogout();
        }
        Test.stopTest();

        Assert.areEqual('CLEARED', status,
            'A CFRIMS failure must not stop the local session being cleared');
        assertSessionCleared(getApplicantAccount());
    }

    // -------------------------------------------------------------------
    // notifyCfrimsLogoutAsync
    // -------------------------------------------------------------------

    @IsTest
    static void testNotifyCfrimsLogoutAsyncRevokesWithoutClearing() {
        User portalUser = getPortalUser();

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        System.runAs(portalUser) {
            OAP_CFRIMS_LogoutService.notifyCfrimsLogoutAsync();
        }
        Test.stopTest();

        if (configExists()) {
            Assert.areEqual(1, calloutCount, 'Revoke must call CFRIMS once');
            Assert.areEqual('Bearer ' + TOKEN, lastAuthHeader,
                'Revoke must use the stored token');
        }
        Assert.areEqual(TOKEN, getApplicantAccount().CFRIMS_Access_Token__pc,
            'This entry point revokes only; clearing is the other method');
    }

    @IsTest
    static void testNotifyCfrimsLogoutAsyncNoAccountIsSilent() {
        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        OAP_CFRIMS_LogoutService.notifyCfrimsLogoutAsync();
        Test.stopTest();

        Assert.areEqual(0, calloutCount,
            'A user with no applicant Account has nothing to revoke');
    }

    // -------------------------------------------------------------------
    // handleLogoutEvents -- the LogoutEventTrigger path
    // -------------------------------------------------------------------

    @IsTest
    static void testHandleLogoutEventsClearsSessionAndRevokes() {
        User portalUser = getPortalUser();

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        OAP_CFRIMS_LogoutService.handleLogoutEvents(new Set<Id>{ portalUser.Id });
        Test.stopTest();

        assertSessionCleared(getApplicantAccount());

        if (configExists()) {
            Assert.areEqual(1, calloutCount,
                'The event path must revoke the CFRIMS session too');
            Assert.areEqual('Bearer ' + TOKEN, lastAuthHeader,
                'The token must be captured before the record is cleared');
        }
    }

    @IsTest
    static void testHandleLogoutEventsIsBulkSafe() {
        User portalUser = getPortalUser();

        // A LogoutEventStream batch can carry up to 2,000 events, so the
        // handler must not issue per-user DML or per-user async jobs.
        Set<Id> userIds = new Set<Id>{ portalUser.Id, UserInfo.getUserId() };

        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        OAP_CFRIMS_LogoutService.handleLogoutEvents(userIds);
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(queries <= 5,
            'Handler must be bulkified; used ' + queries + ' queries');
        assertSessionCleared(getApplicantAccount());
    }

    @IsTest
    static void testHandleLogoutEventsIgnoresEmptyAndNullInput() {
        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        OAP_CFRIMS_LogoutService.handleLogoutEvents(null);
        OAP_CFRIMS_LogoutService.handleLogoutEvents(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, calloutCount, 'Nothing to do, nothing called');
    }

    @IsTest
    static void testHandleLogoutEventsIgnoresUsersWithoutAccount() {
        Test.setMock(HttpCalloutMock.class, new LogoutMock(200));

        Test.startTest();
        OAP_CFRIMS_LogoutService.handleLogoutEvents(
            new Set<Id>{ UserInfo.getUserId() }
        );
        Test.stopTest();

        Assert.areEqual(0, calloutCount,
            'Internal users have no applicant Account and must be skipped');
    }
}
