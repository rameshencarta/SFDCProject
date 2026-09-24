/**
 * @description Queueable that fetches CFRIMS dashboard data after a successful submit.
 *              Also exposes a @future entry point (fetchAsync) for callers that are
 *              already running in a @future context and cannot use System.enqueueJob.
 * @author Ramesh / DND
 * @date 2026-05-26
 * @group Integration Framework  
 */
public class OAP_Cfrims2DashboardFetcher implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_ATTEMPTS = 5;
    
   
    /** OAP Status Codes that mean the application exists in CFRIMS
     *  (10 Submitted … 80 Enrolled); the code → step mapping itself lives in
     *  OAP_Cfrims2DataPullService so both pull paths agree. */
    @TestVisible private static final Set<String> SUBMITTED_STATUS_CODES =
        new Set<String>{ '10', '20', '30', '40', '50', '60', '70', '80' };

    private final Id      accountId;
    private final Id      applicationFormId;
    private final String  email;
    private final Integer attempt;

    public OAP_Cfrims2DashboardFetcher(
            Id accountId, Id applicationFormId, String email) {
        this(accountId, applicationFormId, email, 1);
    }
   
    @TestVisible
    private OAP_Cfrims2DashboardFetcher(
            Id accountId, Id applicationFormId, String email, Integer attempt) {
        this.accountId         = accountId;
        this.applicationFormId = applicationFormId;
        this.email             = email;
        this.attempt           = attempt;
    }   
    
    @future(callout=true)
    public static void fetchAsync(Id accountId, Id applicationFormId, String email) {
        runFetch(accountId, applicationFormId, email, null);
    }

    /**
     * @param handshakeRawBody decrypted handshake body from the caller's own
     *        handshake (null when the caller reused a stored token). The
     *        handshake is the only CFRIMS payload carrying the applicant's
     *        given name / surname, so when none is supplied one is performed
     *        here to keep Account names in sync with CFRIMS.
     */
    @future(callout=true)
    public static void fetchAsync(Id accountId, Id applicationFormId, String email,
                                  String handshakeRawBody) {
        runFetch(accountId, applicationFormId, email, handshakeRawBody);
    }

    private static void runFetch(Id accountId, Id applicationFormId, String email,
                                 String handshakeRawBody) {
        try {
            Account a = [
                SELECT Id, CFRIMS_User_Identifier__pc, CFRIMS_Client_Session_Id__pc,
                       CFRIMS_Access_Token__pc, user_key__pc
                FROM Account WHERE Id = :accountId LIMIT 1
            ];

           
            Map<String, String> session = buildStoredSession(a);
            Boolean didHandshake = false;

            if (session != null && String.isNotBlank(handshakeRawBody)) {
                session.put('rawBody', handshakeRawBody);
            } else if (session != null) {
                session = null; // no name source available: handshake below
            }

            if (session == null) {
               
                session = OAP_CFRIMS_ApiClient.performHandshake(
                    email, a.CFRIMS_User_Identifier__pc, a.CFRIMS_Client_Session_Id__pc);
                didHandshake = true;

                
                if (session.get('require_merge') == '1') {
                    OAP_CFRIMS_ApiClient.CompleteMergeResponse mergeResp =
                        OAP_CFRIMS_ApiClient.completeMerge(session, email);
                    if (String.isNotBlank(mergeResp.decryptedBody)) {
                        Map<String, Object> mergeData =
                            (Map<String, Object>) JSON.deserializeUntyped(
                                mergeResp.decryptedBody);
                        String mergedKey = (String) mergeData.get('user_key');
                        if (String.isNotBlank(mergedKey)) {
                            session.put('user_key', mergedKey);
                        }
                    }
                }
            }

            OAP_CFRIMS_ApiClient.DashboardResponse dashres =
                OAP_CFRIMS_ApiClient.getDashboard(session, email);

           
            if (!didHandshake && isSessionRejected(dashres.res)) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DashboardFetcher.fetchAsync: stored session rejected ('
                    + dashres.res.getStatusCode() + ') — re-handshaking once.');
                session = OAP_CFRIMS_ApiClient.performHandshake(
                    email, a.CFRIMS_User_Identifier__pc, a.CFRIMS_Client_Session_Id__pc);
                didHandshake = true;
                dashres = OAP_CFRIMS_ApiClient.getDashboard(session, email);
            }

           
            Cfrims2HandshakeIdStore.flushPersist();
            CFRIMS_Logger.flush();
            persistSessionIfHandshaken(accountId, session, didHandshake);           

            if (dashres.res.getStatusCode() != 200
                    || String.isBlank(dashres.decryptedBody)) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DashboardFetcher.fetchAsync: dashboard returned '
                    + dashres.res.getStatusCode() + ' — skipping');
                return;
            }

            Map<String, Object> dash =
                (Map<String, Object>) JSON.deserializeUntyped(dashres.decryptedBody);

            applyHandshakeNames(accountId, session);
            new OAP_Cfrims2DashboardFetcher(accountId, applicationFormId, email)
                .applyDashboardToSalesforce(dash, dashres.decryptedBody);

            
            List<Object> tasks  = (List<Object>) dash.get('applicant_tasks');
            Object       occMos = dash.get('occ_display_mos');
            if ((tasks == null || tasks.isEmpty()) && occMos == null
                    && dash.get('applicant_status') == null
                    && !Test.isRunningTest()) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DashboardFetcher.fetchAsync: dashboard looks '
                    + 'unprovisioned (empty tasks, no MOS) — handing off to '
                    + 'Queueable retry.');
                System.enqueueJob(new OAP_Cfrims2DashboardFetcher(
                    accountId, applicationFormId, email));
                return;
            }

            CFRIMS_Logger.CFRIMSlogAPI(
                'fetchAsync', '', 'GET_DASHBOARD_DEFERRED', '',
                dashres.decryptedBody,
                dashres.res.getStatusCode(),
                true, null,
                String.valueOf(accountId),
                String.valueOf(applicationFormId)
            );
            CFRIMS_Logger.flush();

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'OAP_Cfrims2DashboardFetcher.fetchAsync failed: '
                + e.getMessage() + ' line: ' + e.getLineNumber());
            Cfrims2HandshakeIdStore.flushPersist();
            CFRIMS_Logger.flush();
        }
    }   

    public void execute(QueueableContext ctx) {
        Map<String, String> session;
        Boolean didHandshake = false;
        OAP_CFRIMS_ApiClient.DashboardResponse dashres;

        try {
            Account a = [
                SELECT Id, PersonEmail, CFRIMS_User_Identifier__pc,
                       CFRIMS_Client_Session_Id__pc,
                       CFRIMS_Access_Token__pc, user_key__pc
                FROM Account WHERE Id = :accountId LIMIT 1
            ];

           
            session = buildStoredSession(a);

            if (session == null) {
               
                session = OAP_CFRIMS_ApiClient.performHandshake(
                    email, a.CFRIMS_User_Identifier__pc, a.CFRIMS_Client_Session_Id__pc);
                didHandshake = true;
            }

            dashres = OAP_CFRIMS_ApiClient.getDashboard(session, email);
           
            if (!didHandshake && isSessionRejected(dashres.res)) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DashboardFetcher.execute: stored session rejected ('
                    + dashres.res.getStatusCode() + ') — re-handshaking once.');
                session = OAP_CFRIMS_ApiClient.performHandshake(
                    email, a.CFRIMS_User_Identifier__pc, a.CFRIMS_Client_Session_Id__pc);
                didHandshake = true;
                dashres = OAP_CFRIMS_ApiClient.getDashboard(session, email);
            }

            // All callouts done — flush before any DML
            Cfrims2HandshakeIdStore.flushPersist();
            CFRIMS_Logger.flush();
            persistSessionIfHandshaken(accountId, session, didHandshake);

        } catch (Exception e) {
            Cfrims2HandshakeIdStore.flushPersist();
            CFRIMS_Logger.flush();
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.execute: callout failed on attempt '
                + attempt + ' — ' + e.getMessage());
            requeueIfBudgetLeft();
            return;
        }

        if (dashres.res.getStatusCode() != 200 || String.isBlank(dashres.decryptedBody)) {
            requeueIfBudgetLeft();
            return;
        }

        Map<String, Object> dash;
        try {
            dash = (Map<String, Object>) JSON.deserializeUntyped(dashres.decryptedBody);
        } catch (Exception parseEx) {
            return;
        }

        List<Object> tasks  = (List<Object>) dash.get('applicant_tasks');
        Object       occMos = dash.get('occ_display_mos');
        Boolean hasData = dash.get('personal_info') != null || tasks != null;
        // A file CFRIMS has not provisioned yet comes back with null/empty
        // tasks, no MOS and no status: keep polling rather than accept it.
        Boolean looksUnprovisioned = !hasData
            || ((tasks == null || tasks.isEmpty()) && occMos == null
                && dash.get('applicant_status') == null);

        if (hasData) {
            if (didHandshake) applyHandshakeNames(accountId, session);
            applyDashboardToSalesforce(dash, dashres.decryptedBody);
        }

        try {
            CFRIMS_Logger.CFRIMSlogAPI(
                'Dashboard', '/Applicants/dashboard', 'GET_DASHBOARD_DEFERRED', '',
                dashres.decryptedBody,
                dashres.res.getStatusCode(),
                !looksUnprovisioned,
                looksUnprovisioned
                    ? 'Provisioning pending, attempt ' + attempt : '',
                accountId, applicationFormId
            );
            CFRIMS_Logger.flush();
        } catch (Exception logEx) {}

       
        if (looksUnprovisioned) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.execute: dashboard looks '
                + 'unprovisioned (empty tasks, no MOS) on attempt ' + attempt
                + ' — retrying instead of accepting as final.');
            requeueIfBudgetLeft();
            return;
        }
    }
   
    @TestVisible private static Map<String, String> buildStoredSession(Account a) {
        String token = a.CFRIMS_Access_Token__pc;
        if (String.isBlank(token) || isTokenExpired(token)) return null;

        Map<String, Object> claims = decodeJwtClaims(token);
        if (claims == null) return null;

        String sessionKey = claims.get('session_key') != null
            ? String.valueOf(claims.get('session_key')) : null;
        String userKey = claims.get('nameid') != null
            ? String.valueOf(claims.get('nameid'))
            : a.user_key__pc; // nameid claim IS the user_key (verified 21-Jul PP2-TRG)
        if (String.isBlank(sessionKey) || String.isBlank(userKey)) return null;

        String userIdentifier = claims.get('UserIdentifier') != null
            ? String.valueOf(claims.get('UserIdentifier'))
            : a.CFRIMS_User_Identifier__pc;
        String clientSessionId = claims.get('ClientSessionID') != null
            ? String.valueOf(claims.get('ClientSessionID'))
            : a.CFRIMS_Client_Session_Id__pc;

        System.debug('OAP_Cfrims2DashboardFetcher: reusing stored accessToken (session_key from JWT claims).');
        return new Map<String, String>{
            'accessToken'     => token,
            'user_key'        => userKey,
            'session_key'     => sessionKey,
            'userIdentifier'  => userIdentifier,
            'clientSessionId' => clientSessionId
        };
    }
    
    @TestVisible private static Map<String, Object> decodeJwtClaims(String jwt) {
        try {
            List<String> parts = jwt.split('\\.');
            if (parts.size() < 2) return null;
            String b64 = parts[1].replace('-', '+').replace('_', '/');
            while (Math.mod(b64.length(), 4) != 0) { b64 += '='; }
            return (Map<String, Object>) JSON.deserializeUntyped(
                EncodingUtil.base64Decode(b64).toString());
        } catch (Exception e) {
            return null;
        }
    }
   
    @TestVisible private static Boolean isTokenExpired(String jwt) {
        Map<String, Object> claims = decodeJwtClaims(jwt);
        if (claims == null) return true;
        Object expObj = claims.get('exp');
        if (expObj == null) return false;
        try {
            Long expEpoch = Long.valueOf(String.valueOf(expObj));
            Long nowEpoch = DateTime.now().getTime() / 1000;
            return nowEpoch >= (expEpoch - 60);
        } catch (Exception e) {
            return true;
        }
    }
   
    @TestVisible private static Boolean isSessionRejected(HttpResponse res) {
        if (res == null) return false;
        if (res.getStatusCode() == 401) return true;
        String body = res.getBody();
        return String.isNotBlank(body)
            && (body.contains('ORA-20004') || body.contains('Session Mismatch'));
    }
    
    @TestVisible private static void persistSessionIfHandshaken(
            Id accountId, Map<String, String> session, Boolean didHandshake) {
        if (!didHandshake || session == null
                || String.isBlank(session.get('accessToken'))) return;
        try {
            Account tokenUpdate = new Account(
                Id = accountId,
                CFRIMS_Access_Token__pc = session.get('accessToken')
            );
            if (String.isNotBlank(session.get('user_key'))) {
                tokenUpdate.user_key__pc = session.get('user_key');
            }
            update tokenUpdate;
            System.debug('OAP_Cfrims2DashboardFetcher: persisted fresh handshake token to Account.');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.persistSessionIfHandshaken: ' + e.getMessage());
        }
    }

    private void requeueIfBudgetLeft() {
        if (attempt >= MAX_ATTEMPTS) {
            try {
                CFRIMS_Logger.CFRIMSlogAPI(
                    'Dashboard', '/Applicants/dashboard', 'GET_DASHBOARD_DEFERRED', '',
                    'Dashboard never materialised after ' + MAX_ATTEMPTS + ' attempts',
                    null, false, 'Dashboard Timeout',
                    accountId, applicationFormId
                );
                CFRIMS_Logger.flush();
            } catch (Exception logEx) {}
            return;
        }
        if (Test.isRunningTest()) return;
      
        DateTime nextRun = System.now().addMinutes(1);
        String cron = '' + nextRun.second() + ' ' + nextRun.minute() + ' '
            + nextRun.hour() + ' ' + nextRun.day() + ' ' + nextRun.month()
            + ' ? ' + nextRun.year();
        String jobName = 'OAP-DashRetry-' + accountId + '-' + (attempt + 1)
            + '-' + nextRun.getTime();
        try {
            System.schedule(jobName, cron, new DelayedRetry(
                accountId, applicationFormId, email, attempt + 1));
        } catch (Exception e) {
            
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.requeueIfBudgetLeft: schedule '
                + 'failed, falling back to immediate enqueue: ' + e.getMessage());
            System.enqueueJob(new OAP_Cfrims2DashboardFetcher(
                accountId, applicationFormId, email, attempt + 1));
        }
    }   
    
    private class DelayedRetry implements Schedulable {
        private final Id     accountId;
        private final Id     applicationFormId;
        private final String email;
        private final Integer attempt;

        DelayedRetry(Id accountId, Id applicationFormId, String email, Integer attempt) {
            this.accountId         = accountId;
            this.applicationFormId = applicationFormId;
            this.email             = email;
            this.attempt           = attempt;
        }

        public void execute(SchedulableContext ctx) {
            System.enqueueJob(new OAP_Cfrims2DashboardFetcher(
                accountId, applicationFormId, email, attempt));
        }
    }

    /**
     * The Dashboard only carries the surname; given/preferred name changes made in
     * CFRIMS ID are only visible in the handshake's applicant_data.personal_info,
     * so they are applied whenever this fetcher performed a handshake.
     */
    @TestVisible
    private static void applyHandshakeNames(Id accountId, Map<String, String> session) {
        if (session == null || String.isBlank(session.get('rawBody'))) return;
        Map<String, Object> personal;
        try {
            Map<String, Object> root =
                (Map<String, Object>) JSON.deserializeUntyped(session.get('rawBody'));
            Map<String, Object> applicantData = (Map<String, Object>) root.get('applicant_data');
            personal = applicantData == null
                ? null : (Map<String, Object>) applicantData.get('personal_info');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.applyHandshakeNames: bad handshake body: '
                + e.getMessage());
            return;
        }
        if (personal == null) return;

        Account acct    = new Account(Id = accountId);
        Boolean changed = false;
        String given     = stringOf(personal.get('pers_GivenName'));
        String surname   = stringOf(personal.get('pers_Surname'));
        String preferred = stringOf(personal.get('pers_Preferredname'));
        if (String.isNotBlank(given))     { acct.FirstName = given;                 changed = true; }
        if (String.isNotBlank(surname))   { acct.LastName = surname;                changed = true; }
        if (String.isNotBlank(preferred)) { acct.OAP_Preferred_Name__c = preferred; changed = true; }
        if (!changed) return;
        try {
            update acct;
        } catch (Exception updateEx) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.applyHandshakeNames: ' + updateEx.getMessage());
        }
    }

    private static String stringOf(Object v) {
        return v == null ? null : String.valueOf(v).trim();
    }

    @TestVisible
    private void applyDashboardToSalesforce(Map<String, Object> dash, String rawBody) {
        Account acct    = new Account(Id = accountId);
        Boolean changed = false;

        Map<String, Object> personalInfo = (Map<String, Object>) dash.get('personal_info');
        if (personalInfo != null) {
            String alphaNb = (String) personalInfo.get('alpha_nb');
            if (String.isNotBlank(alphaNb)) {
                acct.CFRIMS_Alpha_Number__pc = alphaNb;
                changed = true;
            }
            String surname = stringOf(personalInfo.get('pers_Surname'));
            if (String.isNotBlank(surname)) {
                acct.LastName = surname;
                changed = true;
            }
        }

        Object status = dash.get('applicant_status');
        if (status != null) {
            acct.CFRIMS_Applicant_Status__pc = String.valueOf(status);
            changed = true;
        }

        Object fileStatus = dash.get('applicant_file_status');
        if (fileStatus != null) {
            acct.CFRIMS_Applicant_File_Status__pc = String.valueOf(fileStatus);
            changed = true;
        }

        if (changed) {
            try {
                Database.update(acct, AccessLevel.SYSTEM_MODE);
            } catch (Exception updateEx) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DashboardFetcher.applyDashboardToSalesforce: '
                    + updateEx.getMessage());
                try {
                    CFRIMS_Logger.CFRIMSlogAPI(
                        'applyDashboardToSalesforce', '', 'ACCOUNT_SYNC', '',
                        JSON.serialize(acct), null, false,
                        'Account update failed: ' + updateEx.getMessage(),
                        String.valueOf(accountId), String.valueOf(applicationFormId));
                    CFRIMS_Logger.flush();
                } catch (Exception logEx) {}
            }
        } else {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher.applyDashboardToSalesforce: dashboard '
                + 'carried no personal_info/applicant_status — Account not updated.');
        }
       
        if (dash.containsKey('applicant_appointments')) {
            try {
                OAP_TaskUtils.reconcileDashboardAppointments(
                    accountId,
                    JSON.serialize(dash.get('applicant_appointments'))
                );
            } catch (Exception appointmentEx) {
                System.debug(LoggingLevel.ERROR,
                    'OAP_Cfrims2DashboardFetcher: appointment reconciliation failed: '
                    + appointmentEx.getMessage() + ' | line: ' + appointmentEx.getLineNumber());
            }
        }
        
        Id resolvedFormId = applicationFormId;
        if (resolvedFormId == null) {
            resolvedFormId = OAP_Cfrims2DataPullService.cfrimsSyncedFormId(accountId);
        }
       
        if (resolvedFormId != null) {
            applyStageFromApplicantStatus(resolvedFormId, dash, rawBody);
        }

        if (resolvedFormId != null) {
            Object occMos       = dash.get('occ_display_mos');
            Object occComponent = dash.get('occ_display_component');
            // occ_display_mos present but null = CFRIMS inactivated every
            // occupation; the stale display must be cleared, not kept.
            if (dash.containsKey('occ_display_mos') || occComponent != null) {
                try {
                    ApplicationForm formUpdate = new ApplicationForm(Id = resolvedFormId);
                    Boolean formChanged = false;
                    if (dash.containsKey('occ_display_mos')) {
                        formUpdate.OAP_Occupation_Display__c =
                            occMos == null ? null : String.valueOf(occMos);
                        formChanged = true;
                    }
                    if (occComponent != null) {
                        
                        formUpdate.OAP_Component__c =
                            OAP_CFRIMS_TaskSyncService.normaliseComponent(
                                String.valueOf(occComponent));
                        formChanged = true;
                    }
                    if (formChanged) {
                       
                        Database.update(formUpdate, AccessLevel.SYSTEM_MODE);
                    }
                } catch (Exception occEx) {
                    System.debug(LoggingLevel.WARN,
                        'OAP_Cfrims2DashboardFetcher: occupation display update failed: '
                        + occEx.getMessage());
                }
            }
        }

        if (resolvedFormId != null) {
            try {
                // Log what CFRIMS returned for tasks
                List<Object> rawTasks = (List<Object>) dash.get('applicant_tasks');
                System.debug(LoggingLevel.INFO,
                    'Cfrims2DashboardFetcher: applicant_tasks count from CFRIMS = '
                    + (rawTasks != null ? String.valueOf(rawTasks.size()) : 'null (field missing)'));

                if (rawTasks != null && !rawTasks.isEmpty()) {
                    System.debug(LoggingLevel.INFO,
                        'Cfrims2DashboardFetcher: first task = '
                        + JSON.serialize(rawTasks[0]));

                    // Direct upsert — bypasses OmniProcess/CMT lookup
                    List<Assessment> taskRecords = buildAssessmentsFromJson(
                        dash, resolvedFormId, accountId);
                    if (!taskRecords.isEmpty()) {
                        Integer successCount = new TaskUpsertHelper().doUpsert(taskRecords);
                        // One durable row per run naming any STATUS token the
                        // resolver could not map (Bug 37778).
                        OAP_CFRIMS_TaskSyncService.logUnrecognisedStatuses();
                        if (successCount < taskRecords.size()) {
                            System.debug(LoggingLevel.ERROR,
                                'Cfrims2DashboardFetcher: only ' + successCount + ' of '
                                + taskRecords.size() + ' Assessment(s) actually upserted '
                                + '— see per-row errors above for the rest.');
                        } else {
                            System.debug(LoggingLevel.INFO,
                                'Cfrims2DashboardFetcher: upserted '
                                + successCount + ' Assessment(s)');
                        }
                    }
                } else {
                    System.debug(LoggingLevel.WARN,
                        'Cfrims2DashboardFetcher: CFRIMS returned 0 tasks — '
                        + 'ask recruiter to assign tasks to this applicant in CFRIMS.');
                }
            } catch (Exception taskEx) {
                System.debug(LoggingLevel.ERROR,
                    'Cfrims2DashboardFetcher: task upsert threw: '
                    + taskEx.getMessage() + ' | line: ' + taskEx.getLineNumber());
            }
        } else {
            System.debug(LoggingLevel.WARN,
                'Cfrims2DashboardFetcher: no ApplicationForm found for account '
                + accountId + ' — task sync skipped.');
        }
    }   
   
    @TestVisible
    private static void applyStageFromApplicantStatus(
            Id formId, Map<String, Object> dash, String rawBody) {
        Object statusObj = dash.get('applicant_status');
        String statusCode = statusObj == null ? null : String.valueOf(statusObj);
        if (!SUBMITTED_STATUS_CODES.contains(statusCode)) return;
        try {
            List<ApplicationForm> forms = [
                SELECT Id, Stage, ApplicationStatus
                FROM ApplicationForm WHERE Id = :formId LIMIT 1
            ];
            if (forms.isEmpty()) return;
            ApplicationForm form = forms[0];
            Boolean formChanged = false;
            String binName = OAP_Cfrims2DataPullService.extractBinName(rawBody);
            Boolean cfrimsSaysDraft =
                OAP_Cfrims2DataPullService.isDraftStatusCode(statusCode)
                || OAP_Cfrims2DataPullService.isDraftBin(binName);
            if (!cfrimsSaysDraft
                    && (String.isBlank(form.Stage) || form.Stage == 'Draft')) {
                form.Stage = OAP_Cfrims2DataPullService.stageCompleted();
                formChanged = true;
            }
            String prevStage  = form.Stage;
            String prevStatus = form.ApplicationStatus;
            OAP_Cfrims2DataPullService.applyStatusCodeTransformation(form, statusCode);
            if (String.isNotBlank(binName)) {
                OAP_Cfrims2DataPullService.applyBinTransformation(form, binName);
            }
            if (form.Stage != prevStage || form.ApplicationStatus != prevStatus) {
                formChanged = true;
            }
            if (formChanged) {
                Database.update(form, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception stageEx) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DashboardFetcher: stage/status update failed: '
                + stageEx.getMessage());
        }
    }

    private static List<Assessment> buildAssessmentsFromJson(
            Map<String, Object> dash, Id applicationFormId, Id accountId) {
        List<Object> tasks = (List<Object>) dash.get('applicant_tasks');
        if (tasks == null || tasks.isEmpty()) return new List<Assessment>();

        List<Assessment> records = new List<Assessment>();
        Set<String>      seenIds = new Set<String>();

        
        Map<String, Object> detContact = (Map<String, Object>) dash.get('det_contact');
        String detName    = detContact == null ? null : strOf(detContact.get('det_name'));
        String detEmail   = detContact == null ? null : strOf(detContact.get('det_email'));
        String detPhone   = detContact == null ? null : strOf(detContact.get('det_phone'));
        String detAddress = detContact == null ? null : strOf(detContact.get('det_address'));
        
        Set<String> incomingTaskIds = new Set<String>();
        for (Object o : tasks) {
            Map<String, Object> peek = (Map<String, Object>) o;
            String peekId = strOf(peek.get('APPLICANT_TASK_ID'));
            if (String.isNotBlank(peekId)) incomingTaskIds.add(peekId);
        }
        Map<String, String> existingStatuses =
            OAP_CFRIMS_TaskSyncService.existingStatusByTaskId(incomingTaskIds);

        for (Object o : tasks) {
            Map<String, Object> t      = (Map<String, Object>) o;
            String              taskId = t.get('APPLICANT_TASK_ID') != null
                ? String.valueOf(t.get('APPLICANT_TASK_ID')) : null;
            if (String.isBlank(taskId) || seenIds.contains(taskId)) continue;
            seenIds.add(taskId);

            Assessment rec           = new Assessment();
            rec.Applicant_Task_Id__c = taskId;
            rec.AccountId            = accountId;
            rec.ResponseContextId    = applicationFormId;

            String rawName = t.get('TASK_NAME') != null
                ? String.valueOf(t.get('TASK_NAME')) : 'Task';
            rec.Name = rawName.length() > 80 ? rawName.substring(0, 80) : rawName;

            String dateAssigned = t.get('DATE_ASSIGNED') != null
                ? String.valueOf(t.get('DATE_ASSIGNED')) : null;
            
            rec.Date_Assigned__c = parseApiDate(dateAssigned);

            
            rec.Type_Code__c            = strOf(t.get('TYPE_CODE'));
            rec.Sched_Type_Id__c        = strOf(t.get('SCHED_TYPE_ID'));
            
            rec.Appointment_Id__c = OAP_CFRIMS_TaskSyncService.normaliseExternalId(
                strOf(t.get('APPOINTMENT_ID')));
            rec.Task_Reference_Id__c    = strOf(t.get('TASK_REF_ID'));           
            rec.OAP_Task_Display__c = OAP_CFRIMS_TaskSyncService.taskDisplayFor(
                strOf(t.get('TASK_REF_ID')));
            rec.GROUP_PARENT_ID__c      = parseApiDecimal(strOf(t.get('GROUP_PARENT_ID')));
            rec.GROUP_ID__c             = parseApiDecimal(strOf(t.get('GROUP_ID')));
            rec.OAP_Appointment_Detachment_Name__c  = OAP_CFRIMS_TaskSyncService.normaliseDetachment(detName);
            rec.OAP_Appointment_Detachment_Email__c = detEmail;
            rec.OAP_Appointment_Detachment_Phone__c = detPhone;
            rec.OAP_Appointment_Address__c          = detAddress;
            
            OAP_CFRIMS_TaskSyncService.applyResolvedStatus(
                rec, strOf(t.get('STATUS')), existingStatuses.get(taskId));

            records.add(rec);
        }
        return records;
    }

    private static String strOf(Object o) {
        return o == null ? null : String.valueOf(o);
    }
   
    private static Decimal parseApiDecimal(String s) {
        if (String.isBlank(s)) return null;
        try {
            return Decimal.valueOf(s);
        } catch (Exception e) {
            return null;
        }
    }
   
    private static Date parseApiDate(String s) {
        if (String.isBlank(s)) return null;
        try {
            return Date.valueOf(s);
        } catch (Exception e1) {
            try {
                List<String> parts = s.split('-');
                Map<String, Integer> months = new Map<String, Integer>{
                    'Jan'=>1,'Feb'=>2,'Mar'=>3,'Apr'=>4,'May'=>5,'Jun'=>6,
                    'Jul'=>7,'Aug'=>8,'Sep'=>9,'Oct'=>10,'Nov'=>11,'Dec'=>12
                };
                return Date.newInstance(
                    Integer.valueOf(parts[2]),
                    months.get(parts[1]),
                    Integer.valueOf(parts[0])
                );
            } catch (Exception e2) { return null; }
        }
    }

    private without sharing class TaskUpsertHelper {
       
        public Integer doUpsert(List<Assessment> records) {
            Integer successCount = 0;
            try {
               
                Database.UpsertResult[] results =
                    Database.upsert(records, Assessment.Applicant_Task_Id__c,
                                    false, AccessLevel.SYSTEM_MODE);
                for (Database.UpsertResult r : results) {
                    if (r.isSuccess()) successCount++;
                }               
                OAP_CFRIMS_TaskSyncService.logUpsertFailures(
                    'OAP_Cfrims2DashboardFetcher.doUpsert', records, results);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'TaskUpsertHelper.doUpsert failed: '
                    + e.getMessage() + ' | line: ' + e.getLineNumber());
            }
            return successCount;
        }
    }
}