/**
 * OAP_CFRIMS_LogoutService
 *
 * Revokes the applicant's active CFRIMS session and clears the locally
 * stored session state when they log out of the portal, per CFRIMS API
 * spec section 2.3 (/Auth/logout).
 *
 * Two entry points, by design:
 *
 *  1. clearLocalSessionOnLogout() / notifyCfrimsLogoutAsync() are called
 *     from oapPortalHeaderMenu.js's handleLogout() before it navigates to
 *     the comm__loginPage/logout action. The caller awaits these with a
 *     hard timeout so a slow or unreachable CFRIMS can never block
 *     someone's ability to log out.
 *
 *  2. LogoutEventTrigger (on the LogoutEventStream platform event) routes
 *     into handleLogoutEvents(). This is the reliable path: the LWC only
 *     runs when the applicant uses the custom header menu, so on its own
 *     it misses the standard Experience Cloud profile menu, /secur/logout
 *     and forced session timeouts, leaving the access token on the record.
 *     LogoutEventStream must be enabled in Setup, and note that it is not
 *     published when a user simply closes the browser, nor on an ordinary
 *     session timeout unless "Force logout on session timeout" is on.
 *
 * The event trigger runs asynchronously as Automated Process, so nothing
 * reachable from handleLogoutEvents() may rely on UserInfo.getUserId() --
 * the user is passed explicitly instead.
 *
 * CFRIMS_User_Identifier__pc is deliberately left untouched throughout --
 * it's the applicant's stable CFRIMS identity, not session state, and must
 * be reused (not regenerated) on their next login.
 */
public class OAP_CFRIMS_LogoutService {

    @TestVisible private static final String STATUS_CLEARED    = 'CLEARED';
    @TestVisible private static final String STATUS_NO_ACCOUNT = 'NO_ACCOUNT';
    @TestVisible private static final String STATUS_ERROR      = 'ERROR';

    /**
     * Revokes the CFRIMS session and clears the local session fields for
     * the logged-in portal user.
     *
     * Returns a coarse status rather than throwing: logout must never be
     * blocked by this call. The status lets the caller log a failure
     * instead of assuming success, which a void return made impossible.
     * Details stay in the debug log and are not returned to the client.
     */
    @AuraEnabled
    public static String clearLocalSessionOnLogout() {
        Id userId = UserInfo.getUserId();
        try {
            Account acct = findApplicantAccount(userId);
            if (acct == null) {
                System.debug(LoggingLevel.WARN,
                    '[OAP_CFRIMS_LogoutService] No applicant Account for user '
                    + userId + '; nothing to clear.');
                return STATUS_NO_ACCOUNT;
            }

            // Revoke before clearing. The previous implementation cleared
            // the fields first and had the future method re-read the token
            // from the record, so it always found a blank token and
            // returned without ever calling /Auth/logout.
            if (String.isNotBlank(acct.CFRIMS_Access_Token__pc)) {
                revokeAsync(acct.CFRIMS_Access_Token__pc);
            }

            return clearLocalSession(acct.Id) ? STATUS_CLEARED : STATUS_ERROR;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[OAP_CFRIMS_LogoutService] clearLocalSessionOnLogout failed for user '
                + userId + ': ' + e.getMessage());
            return STATUS_ERROR;
        }
    }

    /**
     * Retained for the existing LWC contract. Redundant when
     * clearLocalSessionOnLogout() is also called -- revoking an already
     * invalid token is harmless and is logged, not thrown.
     */
    @AuraEnabled
    public static void notifyCfrimsLogoutAsync() {
        Id userId = UserInfo.getUserId();
        try {
            Account acct = findApplicantAccount(userId);
            if (acct == null || String.isBlank(acct.CFRIMS_Access_Token__pc)) {
                return;
            }
            revokeAsync(acct.CFRIMS_Access_Token__pc);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[OAP_CFRIMS_LogoutService] notifyCfrimsLogoutAsync failed for user '
                + userId + ': ' + e.getMessage());
        }
    }

    /**
     * Entry point for LogoutEventTrigger. Clears every applicant's session
     * fields in one DML and hands the collected tokens to a single
     * Queueable, so a batch of events costs one callout per token rather
     * than one future method per user.
     */
    public static void handleLogoutEvents(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) return;

        try {
            List<Account> accts = findApplicantAccounts(userIds);
            if (accts.isEmpty()) return;

            List<String> tokens = new List<String>();
            List<Account> toClear = new List<Account>();

            for (Account acct : accts) {
                if (String.isNotBlank(acct.CFRIMS_Access_Token__pc)) {
                    tokens.add(acct.CFRIMS_Access_Token__pc);
                }
                toClear.add(clearedSessionRecord(acct.Id));
            }

            if (!tokens.isEmpty()) {
                System.enqueueJob(new RevokeQueueable(tokens));
            }

            for (Database.SaveResult sr :
                    Database.update(toClear, false, AccessLevel.SYSTEM_MODE)) {
                logSaveErrors(sr);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[OAP_CFRIMS_LogoutService] handleLogoutEvents failed for '
                + userIds.size() + ' user(s): ' + e.getMessage());
        }
    }

    /**
     * Resolves the applicant's person Account.
     *
     * AccountId is a standard field on User for Experience Cloud users, so
     * this needs no semi-join. The previous
     * "Id IN (SELECT Contact.AccountId FROM User ...)" form traversed a
     * relationship inside a semi-join subquery, which is not reliably
     * supported and would have thrown a runtime query exception straight
     * into the swallowing catch block.
     */
    private static Account findApplicantAccount(Id userId) {
        List<Account> accts = findApplicantAccounts(new Set<Id>{ userId });
        return accts.isEmpty() ? null : accts[0];
    }

    private static List<Account> findApplicantAccounts(Set<Id> userIds) {
        List<User> users = Database.queryWithBinds(
            'SELECT AccountId ' +
            'FROM User ' +
            'WHERE Id IN :userIds AND AccountId != NULL',
            new Map<String, Object>{ 'userIds' => userIds },
            AccessLevel.SYSTEM_MODE
        );

        Set<Id> accountIds = new Set<Id>();
        for (User u : users) {
            accountIds.add(u.AccountId);
        }
        if (accountIds.isEmpty()) return new List<Account>();

        return Database.queryWithBinds(
            'SELECT Id, CFRIMS_Access_Token__pc ' +
            'FROM Account ' +
            'WHERE Id IN :accountIds',
            new Map<String, Object>{ 'accountIds' => accountIds },
            AccessLevel.SYSTEM_MODE
        );
    }

    private static Boolean clearLocalSession(Id accountId) {
        Database.SaveResult sr = Database.update(
            clearedSessionRecord(accountId), false, AccessLevel.SYSTEM_MODE
        );
        logSaveErrors(sr);
        return sr.isSuccess();
    }

    private static Account clearedSessionRecord(Id accountId) {
        return new Account(
            Id = accountId,
            CFRIMS_Access_Token__pc       = null,
            CFRIMS_Client_Session_Id__pc  = null,
            user_key__pc                  = null
        );
    }

    private static void logSaveErrors(Database.SaveResult sr) {
        if (sr.isSuccess()) return;

        List<String> errs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
            errs.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        System.debug(LoggingLevel.ERROR,
            '[OAP_CFRIMS_LogoutService] Could not clear local session fields '
            + 'for Account ' + sr.getId() + ': ' + String.join(errs, '; '));
    }

    @future(callout=true)
    private static void revokeAsync(String accessToken) {
        try {
            callLogoutEndpoint(accessToken);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[OAP_CFRIMS_LogoutService] revokeAsync failed: ' + e.getMessage());
        }
    }

    private class RevokeQueueable implements Queueable, Database.AllowsCallouts {
        private final List<String> accessTokens;

        private RevokeQueueable(List<String> accessTokens) {
            this.accessTokens = accessTokens;
        }

        public void execute(QueueableContext ctx) {
            for (String token : accessTokens) {
                try {
                    callLogoutEndpoint(token);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN,
                        '[OAP_CFRIMS_LogoutService] RevokeQueueable failed: '
                        + e.getMessage());
                }
            }
        }
    }

    private static void callLogoutEndpoint(String accessToken) {
        CFRIMS_Config__mdt config = getConfig();

        HttpRequest req = new HttpRequest();
        req.setMethod('POST');
        req.setEndpoint(config.API_Base_URL__c + '/Auth/logout');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('X-Client-Id', config.Client_Id__c);
        req.setHeader('language', 'E');
        // Spec (2.3.3): "The HTTP POST request body must be completely
        // empty." -- not '{}', a genuinely zero-length body.
        req.setBody('');
        req.setTimeout(10000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            // Per spec (2.3.4) a successful logout returns HTTP 200 with no
            // JSON body at all, so there's nothing further to parse either
            // way. Non-200 is logged but not thrown -- see class-level
            // comment on why this stays best-effort.
            System.debug(LoggingLevel.WARN,
                '[OAP_CFRIMS_LogoutService] /Auth/logout returned '
                + res.getStatusCode() + ': ' + res.getBody());
        }
    }

    // Same config-resolution pattern as OAP_CFRIMS_ApiClient's static
    // initializer.
    private static CFRIMS_Config__mdt getConfig() {
        List<Organization> orgs = Database.query(
            'SELECT IsSandbox FROM Organization LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        Boolean isSandbox = orgs.isEmpty() ? false : orgs[0].IsSandbox;
        return CFRIMS_Config__mdt.getInstance(
            isSandbox ? 'CFRIMS_Integration_Sandbox' : 'CFRIMS_Integration_Prod'
        );
    }
}
