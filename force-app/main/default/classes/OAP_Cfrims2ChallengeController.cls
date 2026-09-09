/**
 * @description Challenge controller for the challengeRouter LWC.
 *              Handles handshake, merge state check, challenge submission and completeMerge.
 * @author Ramesh / DND
 * @date 2026-05-26
 * @group Integration Framework
 
 */
public with sharing class OAP_Cfrims2ChallengeController {

    @AuraEnabled
    public static ChallengeContext startSession(String userEmail) {       
        if (String.isBlank(userEmail)) {
            userEmail = UserInfo.getUserEmail();
        }
        if (String.isBlank(userEmail)) {
            throw new AuraHandledException('Email is required.');
        }
        try {
           
            String userIdentifier = null;
            String clientSessionId = null;
            List<Account> accts = [
                SELECT CFRIMS_User_Identifier__pc, CFRIMS_Client_Session_Id__pc,
                       CFRIMS_Sync_Status__pc,
                       CFRIMS_Access_Token__pc,
                       user_key__pc
                FROM Account WHERE PersonEmail = :userEmail LIMIT 1
            ];
            if (!accts.isEmpty() && String.isNotBlank(accts[0].CFRIMS_User_Identifier__pc)) {
                userIdentifier = accts[0].CFRIMS_User_Identifier__pc;
            } else {
                               
                userIdentifier = OAP_Utils.generateSfGuid();
            }
            clientSessionId = (!accts.isEmpty()
                    && String.isNotBlank(accts[0].CFRIMS_Client_Session_Id__pc))
                ? accts[0].CFRIMS_Client_Session_Id__pc
                : OAP_Utils.generateSessGuid();            
            String storedToken   = !accts.isEmpty() ? accts[0].CFRIMS_Access_Token__pc   : null;
            String storedUserKey = !accts.isEmpty() ? accts[0].user_key__pc              : null;
            Map<String, String> handshake = null;
                        
            Boolean didHandshake = false;

            if (String.isNotBlank(storedToken) && !isTokenExpired(storedToken)) {
                Map<String, Object> claims = decodeJwtClaims(storedToken);
                String claimSessionKey = (claims != null && claims.get('session_key') != null)
                    ? String.valueOf(claims.get('session_key')) : null;
                String claimUserKey = (claims != null && claims.get('nameid') != null)
                    ? String.valueOf(claims.get('nameid'))      // nameid claim IS the user_key
                    : storedUserKey;

                if (String.isNotBlank(claimSessionKey) && String.isNotBlank(claimUserKey)) {
                    System.debug('[startSession] Reusing stored accessToken — skipping handshake '
                        + '(session keys decoded from JWT claims)');
                    handshake = new Map<String, String>{
                        'accessToken'     => storedToken,
                        'user_key'        => claimUserKey,
                        'session_key'     => claimSessionKey,
                        'userIdentifier'  => (claims.get('UserIdentifier') != null)
                                                ? String.valueOf(claims.get('UserIdentifier'))
                                                : userIdentifier,
                        'clientSessionId' => (claims.get('ClientSessionID') != null)
                                                ? String.valueOf(claims.get('ClientSessionID'))
                                                : clientSessionId,
                        'rawBody'         => null
                    };
                }
                
            }

            if (handshake == null) {
                System.debug('[startSession] No valid stored token — calling performHandshake');
                handshake = OAP_CFRIMS_ApiClient.performHandshake(
                    userEmail, userIdentifier, clientSessionId);
                didHandshake = true;
            }

            
            if (String.isNotBlank(handshake.get('userIdentifier'))) {
                userIdentifier = handshake.get('userIdentifier');
            }
            if (String.isNotBlank(handshake.get('clientSessionId'))) {
                clientSessionId = handshake.get('clientSessionId');
            }
            // ─────────────────────────────────────────────────────────────────
            CasePayload payload = extractMergePayloadFromHandshake(handshake.get('rawBody'));
           
            Boolean isSynthesised = false;

            if (payload == null) {
                               
                OAP_CFRIMS_ApiClient.MergeStateResponse mergeResp =
                    OAP_CFRIMS_ApiClient.checkMergeState(handshake, userEmail);
               
                if (!didHandshake
                    && mergeResp.res.getStatusCode() != 200
                    && mergeResp.res.getStatusCode() != 404) {
                    System.debug('[startSession] Merge state failed with '
                        + mergeResp.res.getStatusCode()
                        + ' on a reused token — fresh handshake and retrying once');
                    handshake = OAP_CFRIMS_ApiClient.performHandshake(
                        userEmail, userIdentifier, clientSessionId);
                    didHandshake = true;
                    if (String.isNotBlank(handshake.get('userIdentifier'))) {
                        userIdentifier = handshake.get('userIdentifier');
                    }
                    if (String.isNotBlank(handshake.get('clientSessionId'))) {
                        clientSessionId = handshake.get('clientSessionId');
                    }
                    payload = extractMergePayloadFromHandshake(handshake.get('rawBody'));
                    if (payload == null) {
                        mergeResp = OAP_CFRIMS_ApiClient.checkMergeState(handshake, userEmail);
                    }
                }

                if (payload != null) {
                    // fresh handshake carried the merge payload — nothing more to do
                } else if (mergeResp.res.getStatusCode() == 404
                    || (mergeResp.res.getStatusCode() == 200 && String.isBlank(mergeResp.decryptedBody))) {
                    payload = synthesiseNoMergePayload();
                    isSynthesised = true;
                } else if (mergeResp.res.getStatusCode() != 200 || String.isBlank(mergeResp.decryptedBody)) {
                    throw new AuraHandledException('Identity service returned an unexpected response.');
                } else {
                    payload = (CasePayload) JSON.deserialize(mergeResp.decryptedBody, CasePayload.class);
                }
            }

            Boolean accountSubmitted = applyAccountStateOverrides(userEmail, payload);
           
            String verdict;
            if (payload.require_merge != 1) {
                
                Boolean localDraft = latestFormIsDraftOrMissing(userEmail)
                    && !accountSubmitted;
                if (payload.application_completed == 1 && localDraft) {
                    // CFRIMS has a completed file but Salesforce has not caught
                    // up (Draft form / sync in progress) — the applicant must
                    // not start a new application; CFRG resolves the record.
                    System.debug(LoggingLevel.WARN, '[startSession] CFRIMS '
                        + 'reports application_completed=1 but the local form '
                        + 'is Draft/missing for ' + userEmail
                        + ' — routing to Contact CFRG.');
                    verdict = 'OPTION_5_PENDING';
                } else {
                    verdict = (payload.application_completed == 0 && localDraft)
                        ? 'NEW_APPLICANT'
                        : 'ROUTE_BY_STATUS';
                }
            } else if (payload.redirect_to_cfrg == true) {
                verdict = 'OPTION_5_REDIRECT';
            } else if (payload.manual_merge_required == 1) {
                verdict = payload.merge_approved == 1 ? 'COMPLETE_MERGE_AUTO' : 'OPTION_5_PENDING';
            } else {
                verdict = 'SHOW_OPTIONS';
            }           
           
            if (verdict == 'COMPLETE_MERGE_AUTO') {
                try {
                    OAP_CFRIMS_ApiClient.completeMerge(handshake, userEmail);
                } catch (Exception mergeEx) {
                   
                    System.debug('[startSession] completeMerge non-fatal error: ' + mergeEx.getMessage());
                }
            }
            
            try {
                CFRIMS_Logger.flush();
            } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN,
                    '[startSession] log flush failed (non-fatal): ' + logEx.getMessage());
            }

            Id userId = UserInfo.getUserId();
            OAP_Cfrims2SessionCache.putHandshake(userId, handshake);
            OAP_Cfrims2SessionCache.putCasePayload(userId, payload);
            OAP_ChallengeAttemptTracker.reset(userId);
           
            try {
                List<Account> accsToUpdate = [
                    SELECT Id FROM Account
                    WHERE PersonEmail = :userEmail
                    ORDER BY LastModifiedDate DESC
                    LIMIT 1
                ];
                if (!accsToUpdate.isEmpty()) {
                    Account acctToSave = accsToUpdate[0];
                    saveUserIdentifierWithRetry(acctToSave.Id, userIdentifier, userEmail);                                    
                   
                    Map<String, String> sessionToPersist = new Map<String, String>{
                        'clientSessionId' => clientSessionId,
                        'user_key'        => handshake.get('user_key'),
                        'accessToken'     => handshake.get('accessToken')
                    };
                    OAP_CfrimsSessionUtil.persistSessionIfHandshaken(
                        acctToSave.Id, sessionToPersist, didHandshake);
                    
                    if (verdict == 'COMPLETE_MERGE_AUTO' || verdict == 'ROUTE_BY_STATUS') {
                        List<ApplicationForm> existingForms = [
                            SELECT Id FROM ApplicationForm
                            WHERE AccountId = :acctToSave.Id
                            ORDER BY CreatedDate DESC LIMIT 1
                        ];
                       
                        Id formId = existingForms.isEmpty() ? null : existingForms[0].Id;
                        OAP_Cfrims2DashboardFetcher.fetchAsync(acctToSave.Id, formId, userEmail);
                    }
                }
            } catch (Exception saveEx) {
                System.debug(LoggingLevel.ERROR,
                    '[startSession] CFRIMS_IDENTIFIER_SAVE_FAILED — could not save '
                    + 'userIdentifier ' + userIdentifier + ' for ' + userEmail
                    + '. This applicant WILL hit ORA-00001/UK_EMAIL on their next '
                    + 'login unless this identifier is manually restored. Error: '
                    + saveEx.getMessage());
            }

            ChallengeContext result = buildContext(verdict, payload);
            result.resolvedEmail = userEmail;
           
            result.accessToken   = handshake.get('accessToken');
            
            if (!result.applicationCompleted) {
                result.applicationFormId = ensureDraftApplicationForm(userEmail);
            }
            return result;

        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            
            try { CFRIMS_Logger.flush(); } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN,
                    '[startSession] log flush failed (non-fatal): ' + logEx.getMessage());
            }

            String rawMsg = e.getMessage();
           
            if (rawMsg != null && (
                rawMsg.contains('UK_EMAIL') ||
                rawMsg.contains('UK_SF_ID') ||
                rawMsg.contains('UK_USER_KEY') ||   
               
                rawMsg.contains('Cannot get the value of a token type')
            )) {
                try {
                    Integer jsonStart = rawMsg.indexOf('{');
                    if (jsonStart >= 0) {
                        CasePayload recovered = (CasePayload) JSON.deserialize(
                            rawMsg.substring(jsonStart), CasePayload.class);
                        applyAccountStateOverrides(userEmail, recovered);
                        String v;                      
                       
                        Boolean payloadIsEmptyDefaults =
                            (recovered.require_merge == null || recovered.require_merge == 0)
                            && (recovered.application_completed == null || recovered.application_completed == 0)
                            && (recovered.manual_merge_required == null || recovered.manual_merge_required == 0)
                            && (recovered.merge_approved == null || recovered.merge_approved == 0)
                            && recovered.security_question == null;

                        if (payloadIsEmptyDefaults) {                           
                            List<ApplicationForm> localForms = [
                                SELECT Id, Stage FROM ApplicationForm
                                WHERE Account.PersonEmail = :userEmail
                                ORDER BY CreatedDate DESC LIMIT 1
                            ];
                            Boolean localDraft = localForms.isEmpty()
                                || localForms[0].Stage == 'Draft';
                            if (!localDraft) {
                                recovered.application_completed = 1;
                            }
                            v = localDraft ? 'NEW_APPLICANT' : 'ROUTE_BY_STATUS';
                            System.debug(LoggingLevel.ERROR,
                                '[startSession] UK_EMAIL with EMPTY payload for '
                                + userEmail + ' — identifier mismatch suspected; '
                                + 'local-state routing verdict=' + v
                                + '. Restore the original UserIdentifier from '
                                + 'API logs to fully recover this user.');
                        } else if (recovered.require_merge != 1) {
                            // Real payload, no merge required: the email exists                            
                            v = 'ROUTE_BY_STATUS';
                        } else {
                                                      
                            v = 'OPTION_5_PENDING';
                        }
                        Id uid = UserInfo.getUserId();
                        OAP_Cfrims2SessionCache.putCasePayload(uid, recovered);
                        OAP_ChallengeAttemptTracker.reset(uid);
                        ChallengeContext recovCtx = buildContext(v, recovered);
                        recovCtx.resolvedEmail = userEmail;
                        if (!recovCtx.applicationCompleted) {
                            recovCtx.applicationFormId = ensureDraftApplicationForm(userEmail);
                        }
                        return recovCtx;
                    }
                } catch (Exception parseEx) {
                    System.debug('[startSession] UK_EMAIL recovery parse failed: '
                        + parseEx.getMessage());
                }
            }
            
            System.debug(LoggingLevel.ERROR, '[startSession] Unrecovered CFRIMS '
                + 'handshake failure for ' + userEmail + ': ' + rawMsg
                + '\n' + e.getStackTraceString());
           
            ChallengeContext degraded = buildDegradedContext(userEmail);
            if (degraded != null) {
                return degraded;
            }
            throw new AuraHandledException('Identity service unavailable. Please try again shortly.');
        } catch (AuraHandledException ahe) {
            throw ahe; // already user-safe — pass through unchanged
        } catch (Exception ex) {           
           
            System.debug(LoggingLevel.ERROR, '[startSession] Unhandled '
                + ex.getTypeName() + ': ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());
            throw new AuraHandledException('Sign-in check failed ('
                + ex.getTypeName() + '): ' + ex.getMessage());
        }
    }
   
    @TestVisible
    private static ChallengeContext buildDegradedContext(String userEmail) {
        try {
            List<ApplicationForm> forms = [
                SELECT Id, Stage FROM ApplicationForm
                WHERE Account.PersonEmail = :userEmail
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            Boolean isDraft = forms.isEmpty() || forms[0].Stage == 'Draft';

            CasePayload local = synthesiseNoMergePayload();
            if (!isDraft) {
                local.application_completed = 1;
            }
            String verdict = isDraft ? 'NEW_APPLICANT' : 'ROUTE_BY_STATUS';

            Id uid = UserInfo.getUserId();
            OAP_Cfrims2SessionCache.putCasePayload(uid, local);
            OAP_ChallengeAttemptTracker.reset(uid);
            ChallengeContext ctx = buildContext(verdict, local);
            ctx.resolvedEmail = userEmail;
            if (isDraft) {
                ctx.applicationFormId = forms.isEmpty()
                    ? ensureDraftApplicationForm(userEmail)
                    : forms[0].Id;
            }
            System.debug(LoggingLevel.WARN, '[buildDegradedContext] CFRIMS '
                + 'unavailable — degraded routing for ' + userEmail
                + ' stage=' + (forms.isEmpty() ? '(no form)' : forms[0].Stage)
                + ' verdict=' + verdict);
            return ctx;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[buildDegradedContext] failed: '
                + e.getTypeName() + ' | ' + e.getMessage());
            return null;
        }
    }
   
    @TestVisible
    private static Boolean latestFormIsDraftOrMissing(String userEmail) {
        List<ApplicationForm> forms = [
            SELECT Stage FROM ApplicationForm
            WHERE Account.PersonEmail = :userEmail
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        return forms.isEmpty() || forms[0].Stage == 'Draft';
    }
   
    @TestVisible
    private static Id ensureDraftApplicationForm(String userEmail) {
        try {
            List<ApplicationForm> forms = [
                SELECT Id FROM ApplicationForm
                WHERE Account.PersonEmail = :userEmail
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!forms.isEmpty()) {
                return forms[0].Id;
            }
            List<Account> accs = [
                SELECT Id FROM Account
                WHERE PersonEmail = :userEmail
                ORDER BY LastModifiedDate DESC LIMIT 1
            ];
            if (accs.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    '[ensureDraftApplicationForm] no Account for ' + userEmail);
                return null;
            }
            ApplicationForm form = new ApplicationForm(
                AccountId = accs[0].Id,
                Stage     = 'Draft',
                UsageType = 'EmployeeRecruitment'
            );
            insert form;
            return form.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[ensureDraftApplicationForm] failed for ' + userEmail
                + ': ' + e.getTypeName() + ' | ' + e.getMessage());
            return null;
        }
    }  

    @TestVisible private static Map<String, Object> decodeJwtClaims(String jwt) {
        return OAP_CfrimsSessionUtil.decodeJwtClaims(jwt);
    }

    @TestVisible private static Boolean isTokenExpired(String jwt) {
        return OAP_CfrimsSessionUtil.isTokenExpired(jwt);
    }   
   
    @AuraEnabled
    public static Integer getSessionSecondsRemaining() {
        try {
            Account acct = new AccountStateReader()
                .sessionByEmail(UserInfo.getUserEmail());
            if (acct == null || String.isBlank(acct.CFRIMS_Access_Token__pc)) return 0;
            Long remaining = OAP_CfrimsSessionUtil.secondsUntilExpiry(
                acct.CFRIMS_Access_Token__pc);
            if (remaining == null || remaining < 0) return 0;
            return remaining.intValue();
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN,
                '[getSessionSecondsRemaining] ' + ex.getMessage());
            return 0;
        }
    }
   
    @AuraEnabled
    public static Integer extendSession() {
        try {
            Account acct = new AccountStateReader()
                .sessionByEmail(UserInfo.getUserEmail());
            if (acct == null || String.isBlank(acct.CFRIMS_Access_Token__pc)) {
                throw new AuraHandledException(
                    'No active CFRIMS session to extend — please sign in again.');
            }
            String freshToken = OAP_CFRIMS_ApiClient.keepAlive(
                acct.CFRIMS_Access_Token__pc, acct.Id);
            // Callout done — persist the fresh token (DML after callout: OK)
            OAP_CfrimsSessionUtil.persistSessionIfHandshaken(
                acct.Id,
                new Map<String, String>{ 'accessToken' => freshToken },
                true);
            CFRIMS_Logger.flush();
            Long remaining = OAP_CfrimsSessionUtil.secondsUntilExpiry(freshToken);
            return remaining == null ? 0 : remaining.intValue();
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                '[extendSession] ' + ex.getTypeName() + ': ' + ex.getMessage());
            throw new AuraHandledException(
                'Could not extend your session: ' + ex.getMessage());
        }
    }

    @TestVisible
    private static Boolean applyAccountStateOverrides(String userEmail, CasePayload payload) {
        if (payload == null || String.isBlank(userEmail)) return false;
        try {          
            
            AccountStateReader reader = new AccountStateReader();
            List<Account> matches = reader.byEmail(userEmail);
            if (matches.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    '[applyAccountStateOverrides] no Account visible for ' + userEmail);
                return false;
            }
            Account a = matches[0];
            // v4: CFRIMS_Sync_Status__pc = 'Success' is the AUTHORITATIVE
            
            Set<String> submittedStatuses = new Set<String>{
                'Success', 'Submitted', 'Submitted – Pending Dashboard',
                'Submitted - Pending Dashboard', // both dash variants, defensively
                'Pending CFRIMS Sync', 'Manual Review'
            };
            Boolean salesforceSaysSubmitted =
                submittedStatuses.contains(a.CFRIMS_Sync_Status__pc)
                || String.isNotBlank(a.CFRIMS_Alpha_Number__pc)
                || String.isNotBlank(a.CFRIMS_Applicant_Status__pc);

            
            if (!salesforceSaysSubmitted) {
                salesforceSaysSubmitted = reader.hasSubmittedForm(a.Id);
            }

            System.debug('[applyAccountStateOverrides] ' + userEmail
                + ' syncStatus=' + a.CFRIMS_Sync_Status__pc
                + ' alpha=' + a.CFRIMS_Alpha_Number__pc
                + ' applicantStatus=' + a.CFRIMS_Applicant_Status__pc
                + ' → submitted=' + salesforceSaysSubmitted);

            if (salesforceSaysSubmitted) payload.application_completed = 1;
            return salesforceSaysSubmitted;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[applyAccountStateOverrides] failed (non-fatal): ' + e.getMessage());
            return false;
        }
    }

    
    private without sharing class AccountStateReader {
        private List<Account> byEmail(String email) {
            return [
                SELECT Id, CFRIMS_Alpha_Number__pc, CFRIMS_Applicant_Status__pc,
                       CFRIMS_Sync_Status__pc
                FROM Account WHERE PersonEmail = :email LIMIT 1
            ];
        }
        
        private Account sessionByEmail(String email) {
            List<Account> matches = [
                SELECT Id, CFRIMS_Access_Token__pc
                FROM Account WHERE PersonEmail = :email LIMIT 1
            ];
            return matches.isEmpty() ? null : matches[0];
        }

        private Boolean hasSubmittedForm(Id accountId) {
           
            List<ApplicationForm> forms = [
                SELECT Id FROM ApplicationForm
                WHERE AccountId = :accountId
                  AND (Stage = 'Submitted'
                       OR Stage = 'File Submitted (Pending Review)'
                       OR CFRIMS_Synced__c = true)
                LIMIT 1
            ];
            return !forms.isEmpty();
        }
    }

    private static CasePayload extractMergePayloadFromHandshake(String rawBody) {
        if (String.isBlank(rawBody)) return null;
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            Boolean hasMergeContext =
                   raw.get('applicant_data') != null
                || raw.get('require_merge') != null
                || raw.get('option1') != null
                || raw.get('security_question') != null;
            if (!hasMergeContext) return null;
            return (CasePayload) JSON.deserialize(rawBody, CasePayload.class);
        } catch (Exception e) { return null; }
    }

    @AuraEnabled
    public static ChallengeResult submitAnswer(String optionCode, Map<String, Object> answer, String userEmail) {
        if (String.isBlank(optionCode)) {
            throw new AuraHandledException('Missing required input.');
        }
        
        if (String.isBlank(userEmail)) {
            userEmail = UserInfo.getUserEmail();
            System.debug(LoggingLevel.WARN,
                '[submitAnswer] blank userEmail from client — falling back to '
                + userEmail);
        }
        try {
           
            Boolean passed = optionCode == '1'
                ? OAP_SmsOtpService.verifyCode(
                    answer == null || answer.get('code') == null
                        ? null
                        : String.valueOf(answer.get('code')))
                : OAP_Cfrims2ChallengeService.validate(optionCode, answer, userEmail);

            if (passed) {
               
                Map<String, String> handshake = OAP_Cfrims2SessionCache.getHandshake(UserInfo.getUserId());
                OAP_CFRIMS_ApiClient.completeMerge(handshake, userEmail);
                OAP_Cfrims2DataPullService.pull(userEmail);
                CasePayload cached   = OAP_Cfrims2SessionCache.getCasePayload(UserInfo.getUserId());
                Boolean appCompleted = cached != null && cached.application_completed == 1;
                OAP_Cfrims2SessionCache.clear(UserInfo.getUserId());
                return successResult(appCompleted);

            } else {
                Integer remaining = OAP_ChallengeAttemptTracker.recordFailureAndGetRemaining(UserInfo.getUserId());
                if (remaining <= 0) return escalateResult();
                return wrongAnswerResult(remaining);
            }

        } catch (OAP_SmsOtpService.SmsOtpException e) {           
            throw new AuraHandledException(e.getMessage());
        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {            
            
            System.debug(LoggingLevel.ERROR, 'submitAnswer: ' + e.getMessage());
            throw new AuraHandledException('Validation failed. Please try again.');
        }
    }
   
    @AuraEnabled
    public static void triggerManualMerge(String userEmail) {
        if (String.isBlank(userEmail)) {
            throw new AuraHandledException('Email is required.');
        }
        try {
            Account a = [
                SELECT CFRIMS_User_Identifier__pc
                FROM Account WHERE PersonEmail = :userEmail LIMIT 1
            ];
            String userIdentifier = String.isNotBlank(a.CFRIMS_User_Identifier__pc)
                ? a.CFRIMS_User_Identifier__pc
                : OAP_Utils.generateSfGuid();
           
            // CFRG team handles approval asynchronously
            OAP_CalloutService.invoke(JSON.serialize(new Map<String, String>{
                'email'          => userEmail,
                'service'        => 'manualMerge',
                'userIdentifier' => userIdentifier
            }));
            System.debug('OAP_Cfrims2ChallengeController: manualmerge called for ' + userEmail);
        } catch (Exception e) {
            
            System.debug('OAP_Cfrims2ChallengeController: manualmerge failed (non-fatal): '
                + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static void syncPhoneForVerification(String phoneOnFile) {
        try {
            String phone = String.isNotBlank(phoneOnFile) ? phoneOnFile : resolveApplicantPhone();
            if (String.isBlank(phone)) return;
            String e164Phone = formatForVerification(phone);
            List<User> users = [
                SELECT Id, MobilePhone FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
            ];
            if (users.isEmpty()) return;
            if (users[0].MobilePhone != e164Phone) {
                users[0].MobilePhone = e164Phone;
                update users[0];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[syncPhoneForVerification] ' + e.getMessage());
            throw new AuraHandledException('Could not prepare phone verification.');
        }
    }
    
    private static String formatForVerification(String phone) {
        return OAP_Cfrims2ChallengeService.toE164(phone);
    }
   
    private static String resolveApplicantDialCode() {
        return resolveApplicantDialCode(UserInfo.getUserEmail());
    }
    
    @TestVisible
    private static String resolveApplicantDialCode(String applicantEmail) {
        try {
            List<Account> accts = [
                SELECT OAP_Primary_Phone_Country_Code__c
                FROM Account
                WHERE PersonEmail = :applicantEmail
                LIMIT 1
            ];
            if (accts.isEmpty()) return '1';
            return OAP_PhoneRegionUtil.extractDialCodeDigitsOnly(
                accts[0].OAP_Primary_Phone_Country_Code__c, '1'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[resolveApplicantDialCode] ' + e.getMessage());
            return '1';
        }
    }    
    
    @TestVisible
    private static void saveUserIdentifierWithRetry(
            Id accountId, String userIdentifier, String userEmail) {
        Integer attempts = 0;
        Exception lastError = null;
        while (attempts < 2) {
            attempts++;
            try {
                update new Account(Id = accountId, CFRIMS_User_Identifier__pc = userIdentifier);
                return; // success
            } catch (DmlException dex) {
                lastError = dex;
                if (dex.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {                    
                    System.debug(LoggingLevel.ERROR,
                        '[saveUserIdentifierWithRetry] CFRIMS_IDENTIFIER_DUPLICATE — '
                        + 'userIdentifier ' + userIdentifier + ' is already assigned '
                        + 'to a different Account. Email: ' + userEmail
                        + ' Target Account.Id: ' + accountId
                        + ' — DATA INTEGRITY ISSUE, requires admin attention.');
                    return;
                }
                System.debug(LoggingLevel.WARN,
                    '[saveUserIdentifierWithRetry] attempt ' + attempts
                    + ' failed for ' + userEmail + ': ' + dex.getMessage());
            } catch (Exception e) {
                lastError = e;
                System.debug(LoggingLevel.WARN,
                    '[saveUserIdentifierWithRetry] attempt ' + attempts
                    + ' failed for ' + userEmail + ': ' + e.getMessage());
            }
        }
        // Both attempts failed and it wasn't a DUPLICATE_VALUE short-circuit.
        System.debug(LoggingLevel.ERROR,
            '[saveUserIdentifierWithRetry] CFRIMS_IDENTIFIER_SAVE_FAILED after '
            + attempts + ' attempts — userIdentifier ' + userIdentifier
            + ' for ' + userEmail + ' was NOT persisted. This applicant WILL hit '
            + 'ORA-00001/UK_EMAIL on their next login unless this identifier is '
            + 'manually restored. Last error: '
            + (lastError != null ? lastError.getMessage() : 'unknown'));
    }
   
    @AuraEnabled
    public static String requestSmsCode(String userEmail) {
        try {
            String phone = resolveApplicantPhone();
            if (String.isBlank(phone)) {
                throw new OAP_SmsOtpService.SmsOtpException(
                    'We have no phone number on file for you. Please choose a different option.');
            }
            return OAP_SmsOtpService.sendCode(formatForVerification(phone));
        } catch (OAP_SmsOtpService.SmsOtpException e) {
            // Already user-safe: cooldown, unusable number, delivery failure.
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[requestSmsCode] '
                + e.getTypeName() + ': ' + e.getMessage());
            throw new AuraHandledException(System.Label.OAP_Challenge_Sms_SendFailed);
        }
    }

   
    private static String resolveApplicantPhone() {
        CasePayload cached = OAP_Cfrims2SessionCache.getCasePayload(UserInfo.getUserId());
        String phone = cached != null ? cached.phone : null;
        if (String.isBlank(phone)) {
            List<User> users = [
                SELECT MobilePhone FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
            ];
            if (!users.isEmpty()) phone = users[0].MobilePhone;
        }
        return phone;
    }

    @AuraEnabled
    public static Cfrims2SecurityQuestion pickDifferentQuestion(
            String currentQuestionText, List<Cfrims2SecurityQuestion> allQuestions) {
        return OAP_Cfrims2ChallengeService.pickDifferentQuestion(currentQuestionText, allQuestions);
    }   

    public class ChallengeContext {
        @AuraEnabled public String  verdict;
        @AuraEnabled public String  resolvedEmail;
        @AuraEnabled public List<OAP_Cfrims2AvailableOption> availableOptions;
        @AuraEnabled public String  defaultOption;
        @AuraEnabled public String  maskedPhone;
        @AuraEnabled public List<Cfrims2SecurityQuestion> securityQuestions;
        @AuraEnabled public String  referenceNumber;
        @AuraEnabled public Boolean applicationCompleted;
        @AuraEnabled public String  applicationFormId;      
        @AuraEnabled public Boolean inCommunity;
        // Stored on Account after login — reused by sendApplicationToCFRIMS
        // so no second handshake is needed (confirmed by Abakar)
        public String accessToken;
        public ChallengeContext() {}
    }

    private static ChallengeContext buildContext(String v, CasePayload payload) {
        ChallengeContext ctx  = new ChallengeContext();
        ctx.verdict           = v;
        ctx.referenceNumber   = payload.getAlphaNb();
        ctx.applicationCompleted = payload.application_completed == 1;       
        ctx.inCommunity       = Network.getNetworkId() != null;
        // accessToken set by caller (startSession) after successful handshake
        if (v == 'SHOW_OPTIONS') {
            ctx.availableOptions = ChallengeOptionResolver.resolve(payload);
            ctx.defaultOption    = ctx.availableOptions.isEmpty() ? '5' : ctx.availableOptions[0].code;
            ctx.maskedPhone      = MaskUtil.maskPhone(payload.phone);
            ctx.securityQuestions = payload.security_question;
        }
        return ctx;
    }

    public class ChallengeResult {
        @AuraEnabled public String  status;
        @AuraEnabled public Integer attemptsRemaining;
        @AuraEnabled public Boolean applicationCompleted;
        public ChallengeResult() {}
    }

    private static CasePayload synthesiseNoMergePayload() {
        CasePayload p         = new CasePayload();
        p.application_completed = 0;
        p.require_merge         = 0;
        p.manual_merge_required = 0;
        p.merge_approved        = 0;
        p.redirect_to_cfrg      = false;
        return p;
    }

    private static ChallengeResult successResult(Boolean appCompleted) {
        ChallengeResult r      = new ChallengeResult();
        r.status               = 'SUCCESS';
        r.applicationCompleted = appCompleted;
        return r;
    }

    private static ChallengeResult wrongAnswerResult(Integer remaining) {
        ChallengeResult r    = new ChallengeResult();
        r.status             = 'WRONG_ANSWER';
        r.attemptsRemaining  = remaining;
        return r;
    }

    private static ChallengeResult escalateResult() {
        ChallengeResult r = new ChallengeResult();
        r.status          = 'ESCALATE';
        return r;
    }
}