public with sharing class OAP_Cfrims2DataPullService {

    /** Preferred Stage when CFRIMS reports application_completed = 1;
     *  falls back through STAGE_COMPLETED_FALLBACKS to whatever the org's
     *  restricted Stage picklist actually contains. */
    @TestVisible private static final String STAGE_COMPLETED = 'File Submitted (Pending Review)';
    @TestVisible private static final List<String> STAGE_COMPLETED_FALLBACKS =
        new List<String>{ STAGE_COMPLETED, 'Submitted' };

    /** Stage to set when CFRIMS reports application_completed = 0 */
    @TestVisible private static final String STAGE_DRAFT = 'Draft';

    @TestVisible private static final String USAGE_TYPE_DEFAULT = 'EmployeeRecruitment';

    
    @TestVisible private static final Set<String> SUBMITTED_STATUS_CODES =
        new Set<String>{ '20', '30', '40', '50', '60', '70' };

    @TestVisible
    private static final Map<String, String> PREV_SERVICE_MAP = new Map<String, String>{
        '0'     => 'No',
        '1'     => 'Yes',
        'true'  => 'Yes',
        'false' => 'No',
        'yes'   => 'Yes',
        'no'    => 'No'
    };

    @TestVisible
    private static final Map<String, String> PREV_TRADE_MAP = new Map<String, String>{
        '0'     => 'No',
        '1'     => 'Yes',
        'true'  => 'Yes',
        'false' => 'No',
        'yes'   => 'Yes',
        'no'    => 'No'
    };
   
    @TestVisible
    private static final Map<String, String> EDUCATION_ALIAS_MAP = new Map<String, String>{
        'ged'         => 'Equivalency',
        'cegep 1'     => 'Trade Certificate',
        'cegep 2'     => 'College Diploma',
        'cegep 3'     => 'College Diploma'
    };

    @TestVisible
    private static final Map<String, String> APPLICANT_STATUS_MAP = new Map<String, String>{
            '0'   => 'Draft',
            '10'  => 'Draft',
            '20'  => 'Submitted',
            '30'  => 'Assigned',
            '40'  => 'Under Review',
            '50'  => 'On Hold',
            '60'  => 'Successful',
            '70'  => 'Unsuccessful'
        };

    private static Boolean cachedIsSandbox;

    /**
     * Endpoint string used purely for CFRIMS_API_Log_History__c rows,
     * matching the config-based base URL used by OAP_CFRIMS_ApiClient and
     * OAP_ApplicationFormHandler. The actual callout endpoint is set by the ApiClient.
     */
    @TestVisible
    private static String dashboardEndpointForLog() {
        if (cachedIsSandbox == null) {
            List<Organization> orgs = Database.query(
                'SELECT IsSandbox FROM Organization LIMIT 1',
                AccessLevel.SYSTEM_MODE
            );
            cachedIsSandbox = orgs.isEmpty() ? false : orgs[0].IsSandbox;
        }
        CFRIMS_Config__mdt cfg = CFRIMS_Config__mdt.getInstance(
            cachedIsSandbox ? 'CFRIMS_Integration_Sandbox' : 'CFRIMS_Integration_Prod'
        );
        String base = cfg != null ? cfg.API_Base_URL__c : '';
        return (base == null ? '' : base) + '/Applicants/dashboard';
    }

    /** Durable failure log so async/data-pull errors are visible in CFRIMS_API_Log_History__c. */
    private static void logPullFailure(String serviceType, String errorMessage,
            String accountId, String formId) {
        try {
            CFRIMS_Logger.CFRIMSlogAPI(
                serviceType,
                dashboardEndpointForLog(),
                'GET', '', '',
                0,
                false,
                errorMessage == null ? null : errorMessage.abbreviate(255),
                accountId, formId
            );
            CFRIMS_Logger.flush();
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN,
                'logPullFailure: could not write log (non-fatal): ' + logEx.getMessage());
        }
    }

    @future(callout=true)
    public static void pullAsync(String email, String handshakeJson) {
        if (String.isBlank(email) || String.isBlank(handshakeJson)) {
            System.debug(LoggingLevel.WARN, 'pullAsync: missing email or handshake, skipping');
            return;
        }
        Map<String, String> handshake;
        try {
            handshake = (Map<String, String>) JSON.deserialize(handshakeJson, Map<String, String>.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'pullAsync: bad handshake JSON: ' + e.getMessage());
            logPullFailure('dataPullAsync',
                'Bad handshake JSON: ' + e.getMessage(), null, null);
            return;
        }
        try {
            pullWithHandshake(email, handshake);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'pullAsync failed: ' + e.getMessage());
            logPullFailure('dataPullAsync',
                e.getTypeName() + ': ' + e.getMessage(), null, null);
        }
    }

    public static void pull(String email) {
        if (String.isBlank(email)) {
            System.debug(LoggingLevel.WARN, 'OAP_Cfrims2DataPullService.pull: blank email, skipping');
            return;
        }
        Map<String, String> handshake = OAP_Cfrims2SessionCache.getHandshake(UserInfo.getUserId());
        if (handshake == null) {
            throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception(
                'No active CFRIMS session - please sign in again.');
        }
        try {
            pullWithHandshake(email, handshake);
        } catch (Exception e) {
            // Catch any QueryException / NullPointerException from called services
            // so it surfaces as a clear error rather than FATAL_ERROR
            System.debug(LoggingLevel.ERROR,
                'OAP_Cfrims2DataPullService.pull failed for ' + email
                + ': ' + e.getTypeName()
                + ' | ' + e.getMessage()
                + ' | line: ' + e.getLineNumber()
                + ' | stack: ' + e.getStackTraceString());
            throw e; // re-throw so callers know it failed
        }
    }

    private static void pullWithHandshake(String email, Map<String, String> handshake) {
        OAP_CFRIMS_ApiClient.DashboardResponse resp = OAP_CFRIMS_ApiClient.getDashboard(handshake, email);

        // Log the dashboard API call — creates CFRIMS API Log History record
        try {
            CFRIMS_Logger.CFRIMSlogAPI(
                'getDashboard',
                dashboardEndpointForLog(),
                'GET', '', resp.res.getBody(),
                resp.res.getStatusCode(),
                resp.res.getStatusCode() == 200,
                resp.res.getStatusCode() != 200
                    ? 'Dashboard pull failed: ' + resp.res.getStatusCode() : null,
                null, null
            );
            CFRIMS_Logger.flush();
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN,
                'Dashboard API log failed (non-fatal): ' + logEx.getMessage());
        }

        if (resp.res.getStatusCode() != 200 || String.isBlank(resp.decryptedBody)) {
            throw new OAP_CFRIMS_ApiClient.CFRIMS_Exception(
                'Dashboard pull failed: ' + resp.res.getStatusCode());
        }

        String rawDashboardBody = resp.decryptedBody;

        DashboardPayload dashboard;
        try {
            dashboard = (DashboardPayload) JSON.deserialize(
                rawDashboardBody, DashboardPayload.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Could not parse dashboard payload: ' + e.getMessage());
            logPullFailure('dataPullParse',
                'Could not parse dashboard payload: ' + e.getMessage(), null, null);
            return;
        }
        if (dashboard == null) return;

        Map<String, Object> handshakeApplicantData =
            parseHandshakeApplicantData(handshake.get('rawBody'));

        Id accountId = upsertApplicant(
            email, dashboard.personal_info, handshakeApplicantData);
        if (accountId == null) {
            System.debug(LoggingLevel.WARN,
                'Skipping application/task pull - no Account found for ' + email);
            return;
        }

        String userKey = handshake.get('user_key');
        if (String.isNotBlank(userKey) && accountId != null) {
            try {
                Account acctKey = new Account(Id = accountId);
                acctKey.user_key__pc               = userKey;
                acctKey.CFRIMS_User_Identifier__pc = handshake.get('userIdentifier');
                update acctKey;
                System.debug('OAP_Cfrims2DataPullService: user_key set on Account ' + accountId);
            } catch (DmlException e) {
                System.debug(LoggingLevel.WARN,
                    'OAP_Cfrims2DataPullService: could not set user_key on Account: '
                    + e.getMessage());
            }
        }

        // Mapping doc: applicant_status / applicant_file_status → Account
        // (raw CFRIMS codes, same fields the DashboardFetcher writes).
        applyApplicantStatuses(accountId, dashboard);

        Id primaryFormId = upsertApplicationFormFromHandshake(
            accountId, dashboard.applications, handshakeApplicantData, dashboard,
            parseHandshakeCompletedFlag(handshake.get('rawBody')));

        // Mapping doc: occ_display_mos / occ_display_component → ApplicationForm.
        applyOccupationDisplay(primaryFormId, dashboard);
        
        try {
            Map<String, Object> rawRoot =
                (Map<String, Object>) JSON.deserializeUntyped(rawDashboardBody);
            if (rawRoot.containsKey('applicant_appointments')) {
                OAP_TaskUtils.reconcileDashboardAppointments(
                    accountId,
                    JSON.serialize(rawRoot.get('applicant_appointments')));
            }
        } catch (Exception appointmentEx) {
            System.debug(LoggingLevel.ERROR,
                'OAP_Cfrims2DataPullService: appointment reconciliation failed: '
                + appointmentEx.getMessage());
            logPullFailure('dataPullAppointments',
                'Appointment reconciliation failed: ' + appointmentEx.getMessage(),
                String.valueOf(accountId), null);
        }

        // Create ApplicationFormEvaluation if one doesn't exist
        Id evaluationId = findOrCreateEvaluation(primaryFormId);
        System.debug('OAP_Cfrims2DataPullService: evaluationId=' + evaluationId
            + ' | primaryFormId=' + primaryFormId);

        if (primaryFormId != null) {
            try {
                // Pass primaryFormId — task sync service uses form ID not evaluation ID
                OAP_CFRIMS_TaskSyncService.upsertTasks(rawDashboardBody, primaryFormId, accountId);
                System.debug('OAP_Cfrims2DataPullService: tasks upserted for form ' + primaryFormId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Task delegation failed: ' + e.getTypeName()
                    + ' | ' + e.getMessage()
                    + ' | line: ' + e.getLineNumber());
                logPullFailure('dataPullTaskSync',
                    'Task delegation failed: ' + e.getTypeName() + ': ' + e.getMessage(),
                    String.valueOf(accountId), String.valueOf(primaryFormId));
            }
        } else {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DataPullService: skipping task sync — primaryFormId is null');
        }
    }

    /** applicant_status / applicant_file_status → Account (raw CFRIMS codes). */
    @TestVisible
    private static void applyApplicantStatuses(Id accountId, DashboardPayload dashboard) {
        if (accountId == null || dashboard == null) return;
        if (dashboard.applicant_status == null
                && dashboard.applicant_file_status == null) return;
        try {
            Account statusUpdate = new Account(Id = accountId);
            if (dashboard.applicant_status != null) {
                statusUpdate.CFRIMS_Applicant_Status__pc = dashboard.applicant_status;
            }
            if (dashboard.applicant_file_status != null) {
                statusUpdate.CFRIMS_Applicant_File_Status__pc = dashboard.applicant_file_status;
            }
            update statusUpdate;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DataPullService: applicant status update failed: '
                + e.getMessage());
            logPullFailure('dataPullApplicantStatus',
                'Applicant status update failed: ' + e.getMessage(),
                String.valueOf(accountId), null);
        }
    }
   
    @TestVisible
    private static void applyOccupationDisplay(Id formId, DashboardPayload dashboard) {
        if (formId == null || dashboard == null) return;
        if (dashboard.occ_display_mos == null
                && dashboard.occ_display_component == null) return;
        try {
            ApplicationForm formUpdate = new ApplicationForm(Id = formId);
            if (dashboard.occ_display_mos != null) {
                formUpdate.OAP_Occupation_Display__c = dashboard.occ_display_mos;
            }
            if (dashboard.occ_display_component != null) {
                formUpdate.Occupation_Display_Component__c = dashboard.occ_display_component;
            }
            // SYSTEM_MODE for parity with the DashboardFetcher / TaskSyncService
            // mirrors of this mapping — portal users lack reliable FLS here.
            Database.update(formUpdate, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_Cfrims2DataPullService: occupation display update failed: '
                + e.getMessage());
            logPullFailure('dataPullOccDisplay',
                'Occupation display update failed: ' + e.getMessage(),
                null, String.valueOf(formId));
        }
    }

    @TestVisible
    private static Id findOrCreateEvaluation(Id formId) {
        if (formId == null) {
            System.debug(LoggingLevel.WARN,
                'findOrCreateEvaluation: null ApplicationForm Id, returning null');
            return null;
        }
        List<ApplicationFormEvaluation> existing = [
            SELECT Id FROM ApplicationFormEvaluation
            WHERE ApplicationFormId = :formId
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0].Id;

        ApplicationFormEvaluation eval = new ApplicationFormEvaluation();
        eval.ApplicationFormId = formId;
        // Status is not a field on ApplicationFormEvaluation — removed.
        // Decision picklist is set once a reviewer acts on it.
        try {
            insert eval;
            return eval.Id;
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR,
                'Could not create ApplicationFormEvaluation for form '
                + formId + ': ' + e.getMessage());
            return null;
        }
    }

   
    @TestVisible
    private static Boolean parseHandshakeCompletedFlag(String rawHandshakeBody) {
        if (String.isBlank(rawHandshakeBody)) return null;
        try {
            Map<String, Object> root =
                (Map<String, Object>) JSON.deserializeUntyped(rawHandshakeBody);
            Object flag = root.get('application_completed');
            if (flag == null) return null;
            return String.valueOf(flag) == '1';
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'parseHandshakeCompletedFlag: bad handshake body: ' + e.getMessage());
            return null;
        }
    }

    private static Map<String, Object> parseHandshakeApplicantData(String rawHandshakeBody) {
        if (String.isBlank(rawHandshakeBody)) return null;
        try {
            Map<String, Object> root =
                (Map<String, Object>) JSON.deserializeUntyped(rawHandshakeBody);
            Object applicantData = root.get('applicant_data');
            if (applicantData == null) return null;
            return (Map<String, Object>) applicantData;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'parseHandshakeApplicantData: bad handshake body: ' + e.getMessage());
            return null;
        }
    }

    private static Id upsertApplicant(
            String email,
            DashboardPayload.PersonalInfo dashboardInfo,
            Map<String, Object> handshakeApplicantData) {

        List<Account> matches = [
            SELECT Id, PersonEmail,
                   CFRIMS_Alpha_Number__pc,
                   CFRIMS_User_Identifier__pc,
                   user_key__pc,
                   CFRIMS_Sync_Status__pc,
                   CFRIMS_Last_Dashboard_Sync__pc,
                   OAP_Canadian_Service_Number__c,
                   PersonBirthdate, LastName, FirstName,
                   OAP_Birth_City__c, OAP_Birth_Country__c,
                   OAP_Sex_at_Birth__c, PersonGenderIdentity,
                   OAP_Preferred_Name__c,
                   OAP_Twin_Siblings__c,
                   Phone, PersonOtherPhone,
                   OAP_Phone_SMS_Consent__c,
                   OAP_OtherPhone_SMS_Consent__c,
                   OAP_Multiple_Addresses__c,
                   PersonMailingStreet, PersonMailingCity,
                   PersonMailingState, PersonMailingPostalCode,
                   PersonMailingCountry,
                   PersonOtherStreet, PersonOtherCity,
                   PersonOtherState, PersonOtherPostalCode,
                   PersonOtherCountry
            FROM Account
            WHERE PersonEmail = :email
            ORDER BY CreatedDate ASC
            LIMIT 2
        ];

        if (matches.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'No Person Account found with PersonEmail = ' + email);
            return null;
        }
        if (matches.size() > 1) {
            System.debug(LoggingLevel.WARN,
                'Multiple Person Accounts share PersonEmail = ' + email
                + ' — syncing the oldest (' + matches[0].Id + ')');
        }

        Account acct = matches[0];
        Map<String, Object> hsPersonal = readMap(handshakeApplicantData, 'personal_info');

        String givenName = readString(hsPersonal, 'pers_GivenName');
        if (String.isNotBlank(givenName)) acct.FirstName = givenName;

        String surname = readString(hsPersonal, 'pers_Surname');
        if (String.isBlank(surname) && dashboardInfo != null) surname = dashboardInfo.pers_Surname;
        if (String.isNotBlank(surname)) acct.LastName = surname;

        String preferredName = readString(hsPersonal, 'pers_Preferredname');
        if (String.isNotBlank(preferredName)) acct.OAP_Preferred_Name__c = preferredName;

        Boolean twins = readBooleanFlag(hsPersonal, 'pers_Twins');
        if (twins != null) acct.OAP_Twin_Siblings__c = translateBooleanToPicklist(twins);

        String dobStr = readString(hsPersonal, 'pers_DateOfBirth');
        if (String.isNotBlank(dobStr)) {
            try { acct.PersonBirthdate = Date.valueOf(dobStr); }
            catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Unparseable pers_DateOfBirth: ' + dobStr);
            }
        }

        String birthCity = readString(hsPersonal, 'pers_DateOfBirthCity');
        if (String.isNotBlank(birthCity)) acct.OAP_Birth_City__c = birthCity;

        String birthCountry = readString(hsPersonal, 'pers_DateOfBirthCountry');
        if (String.isNotBlank(birthCountry)) {
            String mappedCountry = picklistApiName(
                Account.OAP_Birth_Country__c.getDescribe(),
                OAP_CfrimsAddressHelper.countryName(birthCountry));
            if (mappedCountry != null) {
                acct.OAP_Birth_Country__c = mappedCountry;
            } else {
                System.debug(LoggingLevel.WARN,
                    'Unrecognized pers_DateOfBirthCountry from CFRIMS: ' + birthCountry
                    + ' — leaving OAP_Birth_Country__c unchanged');
            }
        }

        String sex = readString(hsPersonal, 'pers_Sex');
        if (String.isNotBlank(sex)) {
            String mapped = translateSex(sex);
            if (mapped != null) acct.OAP_Sex_at_Birth__c = mapped;
        }

        String gender = readString(hsPersonal, 'pers_Gender');
        if (String.isNotBlank(gender)) {
            String mapped = translateGender(gender);
            if (mapped != null) acct.PersonGenderIdentity = mapped;
        }

        if (dashboardInfo != null && String.isNotBlank(dashboardInfo.alpha_nb))
            acct.CFRIMS_Alpha_Number__pc = dashboardInfo.alpha_nb;
        if (dashboardInfo != null && String.isNotBlank(dashboardInfo.service_nb))
            acct.OAP_Canadian_Service_Number__c = dashboardInfo.service_nb;

        Map<String, Object> hsPrevService = readMap(handshakeApplicantData, 'previous_service');
        String prevServiceNumber = readString(hsPrevService, 'prev_servicenumber');
        if (String.isNotBlank(prevServiceNumber)) acct.OAP_Canadian_Service_Number__c = prevServiceNumber;

        Map<String, Object> hsPhone = readMap(handshakeApplicantData, 'phone');
        String primaryPhone = firstNonBlank(new List<String>{
            readString(hsPhone, 'primary_phone'), readString(hsPhone, 'phone_number'),
            readString(hsPhone, 'primary'), readString(hsPhone, 'number')
        });
        if (String.isNotBlank(primaryPhone)) acct.Phone = primaryPhone;

        String secondaryPhone = readString(hsPhone, 'secondary_phone');
        if (String.isNotBlank(secondaryPhone)) acct.PersonOtherPhone = secondaryPhone;

        Boolean primarySms = readBooleanFlag(hsPhone, 'primary_phone_text');
        if (primarySms != null) acct.OAP_Phone_SMS_Consent__c = primarySms;

        Boolean secondarySms = readBooleanFlag(hsPhone, 'secondary_phone_text');
        if (secondarySms != null) acct.OAP_OtherPhone_SMS_Consent__c = secondarySms;

        Map<String, Object> hsHomeAddress    = readMap(handshakeApplicantData, 'address');
        Map<String, Object> hsMailingAddress = readMap(handshakeApplicantData, 'mailing_address');

        Boolean sameAsHome = readBooleanFlag(hsHomeAddress, 'mailing_same_as_home');
        if (sameAsHome != null) acct.OAP_Multiple_Addresses__c = translateBooleanToPicklist(sameAsHome);

        // Mailing address falls back to the home address when CFRIMS sends none
        // (mailing same as home). Home address always populates the Other address.
        if (hsMailingAddress != null) applyAddress(acct, hsMailingAddress, true);
        else if (hsHomeAddress != null) applyAddress(acct, hsHomeAddress, true);
        if (hsHomeAddress != null) applyAddress(acct, hsHomeAddress, false);

        if (acct.CFRIMS_Sync_Status__pc != 'Failed') {
            acct.CFRIMS_Sync_Status__pc = 'Success';
        }
        acct.CFRIMS_Last_Dashboard_Sync__pc = DateTime.now();

        try {
            update acct;
        } catch (DmlException e) {
           
            System.debug(LoggingLevel.ERROR,
                'Account update failed for ' + acct.Id + ': ' + e.getMessage());
            logPullFailure('dataPullAccountUpdate',
                'Account update failed: ' + e.getMessage(),
                String.valueOf(acct.Id), null);
            try {
                update new Account(
                    Id = acct.Id,
                    CFRIMS_Sync_Status__pc = 'Failed',
                    CFRIMS_Last_Dashboard_Sync__pc = DateTime.now()
                );
            } catch (Exception stampEx) {
                System.debug(LoggingLevel.WARN,
                    'Could not stamp sync failure on Account ' + acct.Id
                    + ': ' + stampEx.getMessage());
            }
        }
        return acct.Id;
    }

    private static Id upsertApplicationFormFromHandshake(
            Id accountId,
            List<DashboardPayload.Application> dashboardApps,
            Map<String, Object> handshakeApplicantData,
            DashboardPayload dashboard,
            Boolean handshakeCompleted) {

        List<ApplicationForm> existing = [
            SELECT Id, AccountId, Stage, SubmissionDate, UsageType,
                   Application_Signature__c, CFRIMS_Synced__c, CFRIMS_Correlation_Id__c,
                   CFRIMS_Last_Sync_Error__c, OAP_Highest_Level_of_Education__c,
                   OAP_Preferred_Language_Correspondence__c,
                   OAP_Preferred_Language_for_Written_Exam__c,
                   OAP_Preferred_Language_Interview__c,
                   OAP_Indigenous_Summer_Program__c,
                   OAP_Consent_Employment_Equity_Data__c,
                   OAP_Self_Identify_Indigenous_Person__c,
                   OAP_Self_Identify_Visible_Minority__c,
                   OAP_Citizen_of_Country_other_than_Canada__c,
                   OAP_Date_Canadian_PR_Granted__c,
                   OAP_Criminal_Record_Active_Obligations__c,
                   OAP_Prior_Service_in_Foreign_Military__c,
                   OAP_Born_Outside_Canada__c,
                   OAP_Ownership_of_Foreign_Assets__c,
                   OAP_Outside_Canada_180_Consecutive_Days__c,
                   OAP_Immediate_Family_Living_Abroad__c,
                   OAP_Previously_Qualified_CAF_Occupation__c,
                   OAP_Prior_Enrolment_Component_CAF__c,
                   OAP_Interested_Reapply_Prior_Role__c
            FROM ApplicationForm
            WHERE AccountId = :accountId
            ORDER BY LastModifiedDate DESC
        ];

        Boolean isNewForm = existing.isEmpty();
        ApplicationForm form = isNewForm ? new ApplicationForm() : existing[0];
        form.AccountId = accountId;
        if (isNewForm) form.UsageType = USAGE_TYPE_DEFAULT;

        if (dashboardApps != null && !dashboardApps.isEmpty()) {
            DashboardPayload.Application cfrimsApp = dashboardApps[0];
            form.Stage = cfrimsApp.application_completed == 1 ? stageCompleted() : STAGE_DRAFT;
            if (String.isNotBlank(cfrimsApp.submission_date)) {
                try { form.SubmissionDate = Date.valueOf(cfrimsApp.submission_date); }
                catch (Exception e) {
                    System.debug(LoggingLevel.WARN,
                        'Unparseable submission_date: ' + cfrimsApp.submission_date);
                }
            }
        } else {
            
            Boolean statusSubmitted = dashboard != null
                && String.isNotBlank(dashboard.applicant_status)
                && SUBMITTED_STATUS_CODES.contains(dashboard.applicant_status);
            if (handshakeCompleted == true || statusSubmitted) {
                if (String.isBlank(form.Stage) || form.Stage == STAGE_DRAFT) {
                    form.Stage = stageCompleted();
                }
            } else if (isNewForm && String.isBlank(form.Stage)) {
                form.Stage = STAGE_DRAFT;
            }
        }

        String submitSignature = readString(handshakeApplicantData, 'submit_signature');
        if (String.isNotBlank(submitSignature)) form.Application_Signature__c = submitSignature;

        String consentDateStr = firstNonBlank(new List<String>{
            readString(handshakeApplicantData, 'submit_consent_date'),
            readString(handshakeApplicantData, 'submit_conditional_offer_date')
        });
        if (String.isNotBlank(consentDateStr) && form.SubmissionDate == null) {
            try {
                String datePart = consentDateStr.length() >= 10
                    ? consentDateStr.substring(0, 10) : consentDateStr;
                form.SubmissionDate = Date.valueOf(datePart);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Unparseable consent date: ' + consentDateStr);
            }
        }
        // Fallback of last resort: a completed application must carry a
        // submission date even when CFRIMS did not return one.
        if (form.SubmissionDate == null && form.Stage == stageCompleted()) {
            form.SubmissionDate = Date.today();
        }

        Map<String, Object> hsPersonal = readMap(handshakeApplicantData, 'personal_info');
        String langCorrespondence = firstNonBlank(new List<String>{
            readString(hsPersonal, 'language_correpondence'),
            readString(hsPersonal, 'language_correspondence'),
            readString(hsPersonal, 'language_official')
        });
        if (langCorrespondence == 'E' || langCorrespondence == 'F')
            form.OAP_Preferred_Language_Correspondence__c = langCorrespondence;

        String langExam = readString(hsPersonal, 'language_exam');
        if (langExam == 'E' || langExam == 'F')
            form.OAP_Preferred_Language_for_Written_Exam__c = langExam;

        String langInterview = readString(hsPersonal, 'language_interview');
        if (langInterview == 'E' || langInterview == 'F')
            form.OAP_Preferred_Language_Interview__c = langInterview;

        String rawEducationLevel = readString(hsPersonal, 'education_level');
        if (String.isNotBlank(rawEducationLevel)) {
            String mappedEdu = educationApiName(rawEducationLevel);
            if (mappedEdu != null) {
                form.OAP_Highest_Level_of_Education__c = mappedEdu;
            } else {
                System.debug(LoggingLevel.WARN,
                    'Unrecognized education_level from CFRIMS: ' + rawEducationLevel);
            }
        }

        Map<String, Object> hsPrevService = readMap(handshakeApplicantData, 'previous_service');
        String prevTrade = readString(hsPrevService, 'prev_trade');
        if (String.isNotBlank(prevTrade)) {
            String mappedTrade = PREV_TRADE_MAP.get(prevTrade.toLowerCase());
            if (mappedTrade != null) form.OAP_Previously_Qualified_CAF_Occupation__c = mappedTrade;
        }
        String prevService = readString(hsPrevService, 'prev_service');
        if (String.isNotBlank(prevService)) {
            String mappedService = PREV_SERVICE_MAP.get(prevService.toLowerCase());
            if (mappedService != null) form.OAP_Prior_Enrolment_Component_CAF__c = mappedService;
        }
        Boolean reapplying = readBooleanFlag(hsPrevService, 'reapplyingForATrade');
        if (reapplying != null) form.OAP_Interested_Reapply_Prior_Role__c = translateBooleanToPicklist(reapplying);

        Map<String, Object> hsDeclaration = readMap(handshakeApplicantData, 'declaration');
        Boolean eeSelf = readBooleanFlag(hsDeclaration, 'ee_selfDeclaration');
        // OAP_Consent_Employment_Equity_Data__c is a Yes/No picklist — not a Checkbox
        if (eeSelf != null) form.OAP_Consent_Employment_Equity_Data__c = translateBooleanToPicklist(eeSelf);
        Boolean eeInd = readBooleanFlag(hsDeclaration, 'ee_indigenous');
        if (eeInd != null) form.OAP_Self_Identify_Indigenous_Person__c = translateBooleanToPicklist(eeInd);
        Boolean eeNon = readBooleanFlag(hsDeclaration, 'ee_nonindigenous');
        if (eeNon != null) form.OAP_Self_Identify_Visible_Minority__c = translateBooleanToPicklist(eeNon);

        Map<String, Object> hsCitizenship = readMap(handshakeApplicantData, 'citizenship');
        Boolean citForeign = readBooleanFlag(hsCitizenship, 'citizenship_foreign');
        if (citForeign != null) form.OAP_Citizen_of_Country_other_than_Canada__c = translateBooleanToPicklist(citForeign);
        String prDateStr = readString(hsCitizenship, 'permanent_resident_date');
        if (String.isNotBlank(prDateStr)) {
            try {
                form.OAP_Date_Canadian_PR_Granted__c = Date.valueOf(
                    prDateStr.length() >= 10 ? prDateStr.substring(0, 10) : prDateStr);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Unparseable permanent_resident_date: ' + prDateStr);
            }
        }

        Map<String, Object> hsBiography = readMap(handshakeApplicantData, 'biography');
        Boolean criminal = readBooleanFlag(hsBiography, 'criminalConviction');
        if (criminal != null) form.OAP_Criminal_Record_Active_Obligations__c = translateBooleanToPicklist(criminal);
        Boolean foreignMil = readBooleanFlag(hsBiography, 'foreignMilitaryService');
        if (foreignMil != null) form.OAP_Prior_Service_in_Foreign_Military__c = translateBooleanToPicklist(foreignMil);
        Boolean bornOut = readBooleanFlag(hsBiography, 'bornOutside');
        if (bornOut != null) form.OAP_Born_Outside_Canada__c = translateBooleanToPicklist(bornOut);
        Boolean assetOut = readBooleanFlag(hsBiography, 'assetOutsideOfCanada');
        if (assetOut != null) form.OAP_Ownership_of_Foreign_Assets__c = translateBooleanToPicklist(assetOut);
        Boolean lifeOut = readBooleanFlag(hsBiography, 'lifeOutsideOfCanada');
        if (lifeOut != null) form.OAP_Outside_Canada_180_Consecutive_Days__c = translateBooleanToPicklist(lifeOut);
        Boolean relOut = readBooleanFlag(hsBiography, 'immediateRelativeOutcan');
        if (relOut != null) form.OAP_Immediate_Family_Living_Abroad__c = translateBooleanToPicklist(relOut);

        Map<String, Object> hsEntryPlan = readMap(handshakeApplicantData, 'entry_plan');
        Boolean indSummer = readBooleanFlag(hsEntryPlan, 'aboriginal_summer_program');
        if (indSummer != null) form.OAP_Indigenous_Summer_Program__c = indSummer;

        form.CFRIMS_Synced__c          = true;
        form.CFRIMS_Last_Sync_Error__c = null;

        if (dashboard != null && String.isNotBlank(dashboard.applicant_status)) {
            String mappedStatus = APPLICANT_STATUS_MAP.get(dashboard.applicant_status);
            if (mappedStatus != null) form.ApplicationStatus = mappedStatus;
        }

        try {
            upsert form;
          
            try {
                CFRIMS_Logger.CFRIMSlogAPI(
                    'dataPullFormUpsert',
                    dashboardEndpointForLog(),
                    'GET', '',
                    (isNewForm ? 'Created' : 'Updated') + ' ApplicationForm ' + form.Id
                        + ' | stage=' + form.Stage
                        + ' | applicationStatus=' + form.ApplicationStatus
                        + ' | dashboardApps='
                        + (dashboardApps == null ? 'null' : String.valueOf(dashboardApps.size()))
                        + ' | handshakeApplicantData='
                        + (handshakeApplicantData == null ? 'absent' : 'present')
                        + ' | handshakeCompleted=' + handshakeCompleted,
                    200, true, null,
                    String.valueOf(accountId), String.valueOf(form.Id)
                );
                CFRIMS_Logger.flush();
            } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN,
                    'Form upsert success log failed (non-fatal): ' + logEx.getMessage());
            }
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'ApplicationForm upsert failed: ' + e.getMessage());
            logPullFailure('dataPullFormUpsert',
                'ApplicationForm upsert failed: ' + e.getMessage(),
                String.valueOf(accountId),
                form.Id != null ? String.valueOf(form.Id) : null);
            try {
                if (form.Id != null) {
                    update new ApplicationForm(
                        Id = form.Id,
                        CFRIMS_Synced__c = false,
                        CFRIMS_Last_Sync_Error__c = e.getMessage().abbreviate(255)
                    );
                }
            } catch (Exception stampEx) {}
            return null;
        }
        return form.Id;
    }


    private static Map<String, Object> readMap(Map<String, Object> parent, String key) {
        if (parent == null) return null;
        Object o = parent.get(key);
        if (o == null) return null;
        if (o instanceof Map<String, Object>) return (Map<String, Object>) o;
        return null;
    }

    private static String readString(Map<String, Object> m, String key) {
        if (m == null) return null;
        Object o = m.get(key);
        return o == null ? null : String.valueOf(o);
    }

    private static Boolean readBooleanFlag(Map<String, Object> m, String key) {
        if (m == null) return null;
        Object o = m.get(key);
        if (o == null) return null;
        if (o instanceof Boolean) return (Boolean) o;
        String s = String.valueOf(o).trim();
        if (s == '1' || s.equalsIgnoreCase('true') || s.equalsIgnoreCase('yes') || s.equalsIgnoreCase('y')) return true;
        if (s == '0' || s.equalsIgnoreCase('false') || s.equalsIgnoreCase('no') || s.equalsIgnoreCase('n')) return false;
        return null;
    }

    private static String translateBooleanToPicklist(Boolean b) {
        if (b == null) return null;
        return b ? 'Yes' : 'No';
    }

    private static String firstNonBlank(List<String> values) {
        if (values == null) return null;
        for (String v : values) {
            if (String.isNotBlank(v)) return v;
        }
        return null;
    }

    private static String resolvedStageCompleted;

    /** First value of STAGE_COMPLETED_FALLBACKS that is an active entry on
     *  ApplicationForm.Stage; defaults to STAGE_COMPLETED if none is found. */
    @TestVisible
    private static String stageCompleted() {
        if (resolvedStageCompleted == null) {
            Schema.DescribeFieldResult dfr = ApplicationForm.Stage.getDescribe();
            for (String candidate : STAGE_COMPLETED_FALLBACKS) {
                if (picklistApiName(dfr, candidate) != null) {
                    resolvedStageCompleted = candidate;
                    break;
                }
            }
            if (resolvedStageCompleted == null) resolvedStageCompleted = STAGE_COMPLETED;
        }
        return resolvedStageCompleted;
    }

    private static Map<String, Map<String, String>> picklistCache =
        new Map<String, Map<String, String>>();

    /** Resolves a raw value to an active picklist API name by matching the
     *  API name or label case-insensitively; null when no entry matches. */
    @TestVisible
    private static String picklistApiName(Schema.DescribeFieldResult dfr, String rawValue) {
        if (dfr == null || String.isBlank(rawValue)) return null;
        String fieldKey = dfr.getName();
        Map<String, String> byLower = picklistCache.get(fieldKey);
        if (byLower == null) {
            byLower = new Map<String, String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (!pe.isActive()) continue;
                byLower.put(pe.getValue().toLowerCase(), pe.getValue());
                if (String.isNotBlank(pe.getLabel())) {
                    byLower.put(pe.getLabel().toLowerCase(), pe.getValue());
                }
            }
            picklistCache.put(fieldKey, byLower);
        }
        return byLower.get(rawValue.trim().toLowerCase());
    }

    private static Map<String, String> educationValuesByLower;

    private static Map<String, String> validEducationApiNames() {
        if (educationValuesByLower == null) {
            educationValuesByLower = new Map<String, String>();
            Schema.DescribeFieldResult dfr =
                ApplicationForm.OAP_Highest_Level_of_Education__c.getDescribe();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) {
                    educationValuesByLower.put(pe.getValue().toLowerCase(), pe.getValue());
                }
            }
        }
        return educationValuesByLower;
    }
   
    @TestVisible
    private static String educationApiName(String rawValue) {
        if (String.isBlank(rawValue)) return null;
        Map<String, String> valid = validEducationApiNames();
        String key = rawValue.trim().toLowerCase();
        if (valid.containsKey(key)) return valid.get(key);
        String alias = EDUCATION_ALIAS_MAP.get(key);
        if (alias != null && valid.containsKey(alias.toLowerCase())) {
            return valid.get(alias.toLowerCase());
        }
        return null;
    }

    @TestVisible
    private static String translateSex(String cfrimsValue) {
        if (String.isBlank(cfrimsValue)) return null;
        String v = cfrimsValue.toUpperCase();
        if (v == 'M') return 'Male';
        if (v == 'F') return 'Female';
        return null;
    }

    /**
     * Maps CFRIMS gender values to PersonGenderIdentity picklist API names.
     * The picklist is restricted: Man = M, Woman = W, Gender Diverse = D.
     * API names must be assigned — labels fail with
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST.
     */
    @TestVisible
    private static String translateGender(String cfrimsValue) {
        if (String.isBlank(cfrimsValue)) return null;
        String v = cfrimsValue.toUpperCase();
        if (v == 'M' || v == 'MAN' || v == 'MALE') return 'M';
        if (v == 'W' || v == 'F' || v == 'WOMAN' || v == 'FEMALE') return 'W';
        if (v == 'X' || v == 'D' || v == 'GENDER DIVERSE' || v == 'NON-BINARY'
            || v == 'NONBINARY' || v == 'OTHER' || v == 'DIVERSE') return 'D';
        return null;
    }

    private static void applyAddress(Account acct, Map<String, Object> addr, Boolean isMailing) {
        if (addr == null) return;
        String street = composeStreetWithFallback(
            readString(addr, 'street_number'), readString(addr, 'street_name'),
            readString(addr, 'unit'), readString(addr, 'pobox'), readString(addr, 'civic_number'));
        String city    = readString(addr, 'city');
        String state   = OAP_CfrimsAddressHelper.provinceName(readString(addr, 'province_code'));
        String postal  = readString(addr, 'postal_code');
        String country = OAP_CfrimsAddressHelper.countryName(readString(addr, 'country_code'));
        if (isMailing) {
            if (String.isNotBlank(street))  acct.PersonMailingStreet     = street;
            if (String.isNotBlank(city))    acct.PersonMailingCity       = city;
            if (String.isNotBlank(state))   acct.PersonMailingState      = state;
            if (String.isNotBlank(postal))  acct.PersonMailingPostalCode = postal;
            if (String.isNotBlank(country)) acct.PersonMailingCountry    = country;
        } else {
            if (String.isNotBlank(street))  acct.PersonOtherStreet     = street;
            if (String.isNotBlank(city))    acct.PersonOtherCity       = city;
            if (String.isNotBlank(state))   acct.PersonOtherState      = state;
            if (String.isNotBlank(postal))  acct.PersonOtherPostalCode = postal;
            if (String.isNotBlank(country)) acct.PersonOtherCountry    = country;
        }
    }

    private static String composeStreetWithFallback(
            String streetNumber, String streetName, String unit,
            String pobox, String civicNumber) {
        String composed = OAP_CfrimsAddressFormatter.composeStreet(unit, streetNumber, streetName);
        if (String.isNotBlank(composed)) return composed;
        if (String.isNotBlank(pobox))       return 'P.O. Box ' + pobox;
        if (String.isNotBlank(civicNumber)) return civicNumber;
        return null;
    }
}