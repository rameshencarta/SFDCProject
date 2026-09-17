/**
 * @description Application Form Handler - submits applicant data to CFRIMS
 * @author Ramesh / DND
 * @date 2026-05-26
 * @group Integration Framework 
 */
public class OAP_ApplicationFormHandler {

    // Recursive guard — prevents infinite loop when Stage ApplicationStatus sync re-fires trigger
    private static Boolean isSyncingStatus = false;
    @TestVisible
    private static Set<String> activeApplicationStatusValues;

    @TestVisible
    private static Set<String> getActiveApplicationStatusValues() {
        if (activeApplicationStatusValues == null) {
            activeApplicationStatusValues = new Set<String>();
            for (Schema.PicklistEntry e :
                    ApplicationForm.ApplicationStatus.getDescribe().getPicklistValues()) {
                if (e.isActive()) activeApplicationStatusValues.add(e.getValue());
            }
        }
        return activeApplicationStatusValues;
    }

    // one ApplicationForm per Account. Blocked at INSERT rather than at    
    public static void beforeInsert(List<ApplicationForm> newForms) {
        Set<Id> accountIds = new Set<Id>();
        for (ApplicationForm f : newForms) {
            if (f.AccountId != null) accountIds.add(f.AccountId);
        }
        if (accountIds.isEmpty()) return;

        // Existing forms already in the database for these accounts.
        Set<Id> accountsWithExistingForm = new Set<Id>();
        for (ApplicationForm existing : [
            SELECT AccountId FROM ApplicationForm
            WHERE AccountId IN :accountIds
        ]) {
            accountsWithExistingForm.add(existing.AccountId);
        }

        // Also catch two new forms for the SAME account inserted together in
        // one DML call — the query above alone wouldn't see either yet.
        Set<Id> seenInThisBatch = new Set<Id>();

        for (ApplicationForm f : newForms) {
            if (f.AccountId == null) continue;
            if (accountsWithExistingForm.contains(f.AccountId)
                    || seenInThisBatch.contains(f.AccountId)) {
                f.addError('This account already has an application on file. '
                    + 'Only one application per account is permitted.');
            } else {
                seenInThisBatch.add(f.AccountId);
            }
        }
    }

    public static void afterUpdate(
            List<ApplicationForm> appFormNew,
            Map<Id,ApplicationForm> appFormOldMap) {

        // Sync Stage → ApplicationStatus whenever Stage changes 
       
        if (!isSyncingStatus) {
            isSyncingStatus = true;
            try {
                Set<String> allowed = getActiveApplicationStatusValues();
                List<ApplicationForm> toSync = new List<ApplicationForm>();
                List<String> skipped = new List<String>();
                for (ApplicationForm aform : appFormNew) {
                    if (aform.Stage == appFormOldMap.get(aform.Id).Stage
                        || aform.Stage == aform.ApplicationStatus) {
                        continue;
                    }
                    if (!allowed.contains(aform.Stage)) {
                        skipped.add(aform.Stage);
                        continue;
                    }
                    toSync.add(new ApplicationForm(
                        Id                = aform.Id,
                        ApplicationStatus = aform.Stage
                    ));
                }
                if (!skipped.isEmpty()) {
                    System.debug(LoggingLevel.WARN,
                        '[afterUpdate] Stage->ApplicationStatus mirror skipped for '
                        + skipped.size() + ' record(s): Stage value(s) '
                        + String.join(skipped, ', ')
                        + ' are not active ApplicationStatus values. '
                        + 'ApplicationStatus left as-is.');
                }
                if (!toSync.isEmpty()) {
                    update toSync;
                    System.debug('[afterUpdate] Synced ApplicationStatus = Stage for '
                        + toSync.size() + ' record(s)');
                }
            } catch (Exception e) {
                // Belt and braces: the mirror is bookkeeping and must never be the
                // reason an ApplicationForm update fails.
                System.debug(LoggingLevel.ERROR,
                    '[afterUpdate] Stage->ApplicationStatus mirror failed, continuing: '
                    + e.getTypeName());
            } finally {
                isSyncingStatus = false;
            }
        }

        // CFRIMS submission — fires when Stage changes TO 'Submitted'
        Set<Id> submittedFormIds = new Set<Id>();
        for (ApplicationForm aform : appFormNew) {
            if (aform.Stage == 'Submitted'
                && aform.Stage != appFormOldMap.get(aform.Id).Stage) {
                submittedFormIds.add(aform.Id);
            }
        }
        if (submittedFormIds.isEmpty()) return;

        ensureUserKeysAreSet(submittedFormIds);

        if (System.isFuture() || System.isBatch()) {
            System.debug(LoggingLevel.INFO,
                'OAP_ApplicationFormHandler.afterUpdate: running in @future/@batch context '
                + '— skipping sendApplicationToCFRIMS to avoid nested @future call.');
            return;
        }

        for (Id formId : submittedFormIds) {
            sendApplicationToCFRIMS(formId);
        }
    }

    @TestVisible
    private static void ensureUserKeysAreSet(Set<Id> applicationFormIds) {
        Map<Id, Id> formToAccount = new Map<Id, Id>();
        for (ApplicationForm f : [
            SELECT Id, AccountId FROM ApplicationForm WHERE Id IN :applicationFormIds
        ]) {
            if (f.AccountId != null) formToAccount.put(f.Id, f.AccountId);
        }
        if (formToAccount.isEmpty()) return;

        List<Account> needsKey = [
            SELECT Id, CFRIMS_User_Identifier__pc
            FROM Account
            WHERE Id IN :formToAccount.values()
              AND (CFRIMS_User_Identifier__pc = null OR CFRIMS_User_Identifier__pc = '')
        ];
        if (needsKey.isEmpty()) return;

        for (Account a : needsKey) {
            a.CFRIMS_User_Identifier__pc = generateSfGuid();
        }
        try {
            update needsKey;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'OAP_ApplicationFormHandler.ensureUserKeysAreSet: ' + e.getMessage());
        }
    }
    
    @TestVisible private static final Integer MAX_SUBMIT_ATTEMPTS  = 3;
    @TestVisible private static final Integer RETRY_DELAY_MINUTES  = 2;

    public class SubmissionResult {
        public Boolean success;
        public String status;
        public String message;
        public String errorCode;
    }

    @future(callout=true)
    public static void sendApplicationToCFRIMS(Id applicationFormId) {
        submitWithAttempt(applicationFormId, 1);
    }

    //  delayed retry job for transient CFRIMS DB failures.
    // Queueable (not @future) so it can carry the attempt counter and be
    // scheduled with a delay. AllowsCallouts for the handshake/submit.
    public class SubmitRetryJob implements Queueable, Database.AllowsCallouts {
        private final Id formId;
        private final Integer attempt;
        public SubmitRetryJob(Id formId, Integer attempt) {
            this.formId  = formId;
            this.attempt = attempt;
        }
        public void execute(QueueableContext ctx) {
            System.debug(LoggingLevel.INFO,
                'OAP_ApplicationFormHandler.SubmitRetryJob: attempt ' + attempt
                + ' of ' + MAX_SUBMIT_ATTEMPTS + ' for form ' + formId);
            submitWithAttempt(formId, attempt);
        }
    }

    // shared submit body — attempt 1 arrives via the @future entry point   

    @TestVisible
    private static Boolean hasAlreadySynced(Id applicationFormId) {
        //Resubmit guard 
       
        List<CFRIMS_API_Log_History__c> priorSuccess = [
            SELECT Id FROM CFRIMS_API_Log_History__c
            WHERE Correlation_Id__c = :String.valueOf(applicationFormId)
              AND Success__c = true
            LIMIT 1
        ];
        if (!priorSuccess.isEmpty()) {
            System.debug(LoggingLevel.INFO,
                'OAP_ApplicationFormHandler: ApplicationForm '
                + applicationFormId + ' already has a successful CFRIMS '
                + 'sync logged — skipping duplicate submit.');
            return true;
        }
        return false;
    }

    // Holds the primary PersonEmployment record and the derived cadets array.
    private class EmploymentContext {
        PersonEmployment personEmp;
        List<Map<String, Object>> cadetsPayload = new List<Map<String, Object>>();
    }

    @TestVisible
    private static EmploymentContext loadEmploymentContext(Id accountId) {
       
        EmploymentContext ctx = new EmploymentContext();
        List<PersonEmployment> personEmpList = new List<PersonEmployment>();
        try {
            personEmpList = [
                SELECT OAP_Previous_Service_Reg_Force__c,
                       OAP_Previous_Service_Reserve__c,
                       OAP_Previous_Service_COATS__c,
                       OAP_Previous_Service_Rangers__c,
                       OAP_Cadet_Unit_Name__c,
                       OAP_Cadet_Unit_Type__c,
                       StartDate,
                       EndDate
                FROM PersonEmployment
                WHERE RelatedPersonId = :accountId
            ];
            if (!personEmpList.isEmpty()) ctx.personEmp = personEmpList[0];
        } catch (Exception empEx) {
            System.debug(LoggingLevel.WARN,
                'OAP_ApplicationFormHandler: PersonEmployment query failed: '
                + empEx.getMessage());
        }
        for (PersonEmployment emp : personEmpList) {
            if (String.isNotBlank(emp.OAP_Cadet_Unit_Type__c)
                    || String.isNotBlank(emp.OAP_Cadet_Unit_Name__c)) {
                ctx.cadetsPayload.add(new Map<String, Object>{
                    'unit_type'  => nullToBlank(emp.OAP_Cadet_Unit_Type__c),
                    'unit_name'  => nullToBlank(emp.OAP_Cadet_Unit_Name__c),
                    'start_date' => formatDate(emp.StartDate),
                    'end_date'   => formatDate(emp.EndDate)
                });
            }
        }
        return ctx;
    }

    @TestVisible
    private static List<Map<String, Object>> buildMosList(Id applicationFormId) {
        // MOS from ApplicationFormRelation  JobPosition. preference       
        List<Map<String, Object>> mosList = new List<Map<String, Object>>();
        String mos1 = ''; String mos2 = ''; String mos3 = '';
        String ep1 = ''; String ep2 = ''; String ep3 = '';
        try {
            List<ApplicationFormRelation> afrList = [
                SELECT OAP_MOS_Preferred_Ranking__c, ReferenceRecordId, OAP_Entry_Plan_Id__c
                FROM ApplicationFormRelation
                WHERE ApplicationFormId = :applicationFormId
                  AND ReferenceRecordId != null
                ORDER BY OAP_MOS_Preferred_Ranking__c ASC NULLS LAST
                LIMIT 3
            ];
            Set<Id> jpIds = new Set<Id>();
            for (ApplicationFormRelation afr : afrList) jpIds.add(afr.ReferenceRecordId);
            Map<Id, JobPosition> jpMap = new Map<Id, JobPosition>([
                SELECT Id, Code FROM JobPosition WHERE Id IN :jpIds
            ]);
            if (afrList.size() > 0) {
                mos1 = jpMap.containsKey(afrList[0].ReferenceRecordId)
                    ? nullToBlank(jpMap.get(afrList[0].ReferenceRecordId).Code) : '';
                ep1  = nullToBlank(afrList[0].OAP_Entry_Plan_Id__c);
            }
            if (afrList.size() > 1) {
                mos2 = jpMap.containsKey(afrList[1].ReferenceRecordId)
                    ? nullToBlank(jpMap.get(afrList[1].ReferenceRecordId).Code) : '';
                ep2  = nullToBlank(afrList[1].OAP_Entry_Plan_Id__c);
            }
            if (afrList.size() > 2) {
                mos3 = jpMap.containsKey(afrList[2].ReferenceRecordId)
                    ? nullToBlank(jpMap.get(afrList[2].ReferenceRecordId).Code) : '';
                ep3  = nullToBlank(afrList[2].OAP_Entry_Plan_Id__c);
            }
        } catch (Exception mosEx) {
            System.debug(LoggingLevel.WARN, 'MOS lookup failed: ' + mosEx.getMessage());
        }
        if (String.isNotBlank(mos1)) {
            mosList.add(new Map<String, Object>{ 'preference' => 1, 'code' => padMosCode(mos1), 'entry_plan' => ep1 });
        }
        if (String.isNotBlank(mos2)) {
            mosList.add(new Map<String, Object>{ 'preference' => 2, 'code' => padMosCode(mos2), 'entry_plan' => ep2 });
        }
        if (String.isNotBlank(mos3)) {
            mosList.add(new Map<String, Object>{ 'preference' => 3, 'code' => padMosCode(mos3), 'entry_plan' => ep3 });
        }
        return mosList;
    }

    
    @TestVisible
    private static String padMosCode(String code) {
        if (String.isBlank(code)) return code;
        return code.trim().leftPad(5, '0');
    }

    @TestVisible
    private static List<Map<String, Object>> buildIspList(String ispOptions) {
        // Indigenous Summer Program array (v7.3). Confirmed shape per CFRIMS        
        // Up to 3 programs, ordered by selection sequence.
        List<Map<String, Object>> ispList = new List<Map<String, Object>>();
        if (String.isNotBlank(ispOptions)) {
            Integer ispOrder = 1;
            for (String program : ispOptions.split(';')) {
                String key = program.trim().toLowerCase().replace(' ', '_');
                if (String.isNotBlank(key) && ispOrder <= 3) {
                    ispList.add(new Map<String, Object>{ 'name' => key, 'order' => ispOrder });
                    ispOrder++;
                }
            }
        }
        return ispList;
    }

    @TestVisible
    private static String resolveUserIdentifier(Account acct, String email) {
        // Priority: stored on Account → stored in HandshakeIdStore → generate
        // fresh. Prevents UK_USER_KEY when the Account field is blank but the
        // store already has a valid identifier from a prior handshake/merge.
        String userIdentifier = acct.CFRIMS_User_Identifier__pc;
        if (String.isBlank(userIdentifier)) {
            Map<String, String> stored = Cfrims2HandshakeIdStore.lookup(email);
            String storedId = stored.get('userIdentifier');
            userIdentifier = String.isNotBlank(storedId) ? storedId : generateSfGuid();
            System.debug('OAP_ApplicationFormHandler: userIdentifier resolved: '
                + userIdentifier);
        }
        return userIdentifier;
    }

    // Holds the resolved session token plus whether a fallback handshake ran.
    private class TokenResolution {
        String accessToken;
        String userKey;
        String userIdentifier;
        String clientSessionId;
        Boolean didHandshake = false;
    }

    @TestVisible
    private static TokenResolution resolveAccessToken(
            Account acct, String userIdentifier, String email) {
        
        TokenResolution tr = new TokenResolution();
        tr.accessToken    = acct.CFRIMS_Access_Token__pc;
        tr.userKey        = acct.user_key__pc;
        tr.userIdentifier = userIdentifier;
        tr.clientSessionId = acct.CFRIMS_Client_Session_Id__pc;

        if (String.isBlank(tr.accessToken) || isTokenExpired(tr.accessToken)) {
            System.debug(LoggingLevel.INFO,
                'OAP_ApplicationFormHandler: '
                + (String.isBlank(tr.accessToken) ? 'no stored' : 'expired stored')
                + ' accessToken for ' + email
                + ' — performing fallback handshake before submit.');
            // v11 fix (Aug 2026): if no clientSessionId is stored yet (exactly
           
            if (String.isBlank(tr.clientSessionId)) {
                tr.clientSessionId = 'SF_SESS_' + String.valueOf(Crypto.getRandomLong());
            }
            Map<String, String> hs = OAP_CFRIMS_ApiClient.performHandshake(
                email, userIdentifier, tr.clientSessionId);
            tr.accessToken    = hs.get('accessToken');
            tr.userKey        = hs.get('user_key');
            tr.userIdentifier = hs.get('userIdentifier');
            tr.didHandshake   = true;
            System.debug('OAP_ApplicationFormHandler: fallback handshake OK — '
                + 'userIdentifier=' + tr.userIdentifier);
        } else {
            System.debug('OAP_ApplicationFormHandler: using stored accessToken for ' + email);
        }
        return tr;
    }

    // v10: extracted from submitWithAttempt (was inline, ~190 lines) so the
    // payload shape can be reviewed and unit-tested independently of the
    // callout/DML orchestration. Pure function — no callouts, no DML.
    @TestVisible
    private static Map<String, Object> buildApplicantPayload(
            ApplicationForm appForm,
            PersonEmployment personEmp,
            List<Map<String, Object>> cadetsPayload,
            List<Map<String, Object>> mosList,
            List<Map<String, Object>> ispList) {
            Map<String, Object> applicant = new Map<String, Object>();
            String langOfficial = translateLanguageToCode(appForm.Account.Primary_Language__c);

            applicant.put('personal_info', new Map<String, Object>{
                'pers_GivenName'           => appForm.Account.FirstName,
                'pers_Surname'             => appForm.Account.LastName,
                'pers_Preferredname'       => nullToBlank(appForm.Account.OAP_Preferred_Name__c),
                'pers_DateOfBirth'         => formatDate(appForm.Account.PersonBirthdate),
                'pers_Twins'               => boolToInt(appForm.Account.OAP_Twin_Siblings__c),
                'pers_Sex'                 => translateSex(appForm.Account.OAP_Sex_at_Birth__c),
                'pers_Gender'              => translateGender(appForm.Account.PersonGenderIdentity),
                // education_level is in career_choice per updated CFRIMS payload spec
                'language_official'        => langOfficial,
                'language_correpondence'   => firstNonBlank(appForm.OAP_Preferred_Language_Correspondence__c, langOfficial),
                'language_exam'            => firstNonBlank(appForm.OAP_Preferred_Language_for_Written_Exam__c, langOfficial),
                'language_interview'       => firstNonBlank(appForm.OAP_Preferred_Language_Interview__c, langOfficial),
                'pers_DateOfBirthCity'     => nullToBlank(appForm.Account.OAP_Birth_City__c),
                'pers_DateOfBirthProvince' => nullToBlank(appForm.Account.OAP_Birth_Province_State__c),
                'pers_DateOfBirthCountry'  => toIso2Country(appForm.Account.OAP_Birth_Country__c),
                // service_nb — Applicant Service Number (SN), e.g. "B12345678".
                'service_nb'               => nullToBlank(appForm.Account.OAP_Canadian_Service_Number__c)
            });
            applicant.put('previous_service', new Map<String, Object>{
                // All flags are integers 0/1 per updated CFRIMS JSON spec
                // PREVIOUS_CANADIAN_SERVICE and prev_component removed — not in new spec
                'reapplyingForATrade'        => boolToInt(appForm.OAP_Interested_Reapply_Prior_Role__c),
                'prev_service'               => boolToInt(appForm.OAP_Prior_Enrolment_Component_CAF__c),
                'prev_servicenumber'         => nullToBlank(appForm.OAP_Previous_Service_Number__c),
                'prev_regforce'              => personEmp != null ? boolToInt(personEmp.OAP_Previous_Service_Reg_Force__c) : 0,
                'prev_reserve'               => personEmp != null ? boolToInt(personEmp.OAP_Previous_Service_Reserve__c)   : 0,
                'prev_coats'                 => personEmp != null ? boolToInt(personEmp.OAP_Previous_Service_COATS__c)     : 0,
                'prev_rangers'               => personEmp != null ? boolToInt(personEmp.OAP_Previous_Service_Rangers__c)   : 0,
                'prev_cadets'                => (cadetsPayload != null && !cadetsPayload.isEmpty()) ? 1 : 0,
                'prev_service_qualified_mos' => nullToBlank(appForm.OAP_Previously_Qualified_CAF_Occupation__c),
                'cadets'                     => cadetsPayload
            });
            String prNumber = String.isNotBlank(appForm.OAP_Permanent_Resident_Number__c)
                ? appForm.OAP_Permanent_Resident_Number__c
                : appForm.Account.Permanent_Resident_Number__c;
            Date prDate = appForm.OAP_Date_Canadian_PR_Granted__c != null
                ? appForm.OAP_Date_Canadian_PR_Granted__c
                : appForm.Account.Permanent_Resident_Effective_Date__c;
            Integer isPr = (isPermanentResident(appForm.Account.OAP_Citizenship__c) == 1
                || String.isNotBlank(prNumber) || prDate != null) ? 1 : 0;

            applicant.put('citizenship', new Map<String, Object>{
                // Integers per new spec: 1 = yes, 0 = no
                'citizenship_canadian'              => isCanadianCitizen(appForm.Account.OAP_Citizenship__c),
                'citizenship_permanent'             => isPr,
                'citizenship_foreign'               => boolToInt(appForm.OAP_Citizen_of_Country_other_than_Canada__c),
                'citizenship_date'                  => formatDate(appForm.OAP_Date_Canadian_Citizenship_Granted__c),
                'permanent_resident_date'           => formatDate(prDate),
                'date_permanent_resident_granted'   => formatDate(prDate),
                'date_entry_in_Canada'              => formatDate(appForm.OAP_Date_Entry_In_Canada__c),
                'permanent_resident_number'         => nullToBlank(prNumber)
            });

            String homeProvinceCode = OAP_CfrimsAddressHelper.provinceCode(appForm.Account.PersonOtherState);
            if (homeProvinceCode == null) homeProvinceCode = '';
            OAP_CfrimsAddressFormatter.ParsedStreet home =
                OAP_CfrimsAddressFormatter.parseStreet(appForm.Account.PersonOtherStreet);
            Boolean sameAsHome = isMailingSameAsHome(appForm.Account);
            applicant.put('address', new Map<String, Object>{
                'full'              => '',
                'unit'              => home.unitNumber,
                'street_number'     => home.streetNumber,
                'street_name'       => home.streetName,
                'pobox'             => '',
                'civic_number'      => '',
                'city'              => nullToBlank(appForm.Account.PersonOtherCity),
                'province_code'     => homeProvinceCode,
                'province_other'    => '',
                'postal_code'       => nullToBlank(appForm.Account.PersonOtherPostalCode),
                'Country_code'      => toIso2Country(appForm.Account.PersonOtherCountry),
                'other_information' => '',
                'mailing_same_as_home' => boolToInt(sameAsHome),
                'is_mailing'        => 0
            });

            String mailProvinceCode;
            OAP_CfrimsAddressFormatter.ParsedStreet mail;
            String mailCity;
            String mailPostalCode;
            String mailCountryCode;

            if (sameAsHome) {
                mailProvinceCode = homeProvinceCode;
                mail             = home;
                mailCity         = nullToBlank(appForm.Account.PersonOtherCity);
                mailPostalCode   = nullToBlank(appForm.Account.PersonOtherPostalCode);
                mailCountryCode  = toIso2Country(appForm.Account.PersonOtherCountry);
            } else {
                mailProvinceCode = OAP_CfrimsAddressHelper.provinceCode(appForm.Account.PersonMailingState);
                if (mailProvinceCode == null) mailProvinceCode = '';
                mail             = OAP_CfrimsAddressFormatter.parseStreet(appForm.Account.PersonMailingStreet);
                mailCity         = nullToBlank(appForm.Account.PersonMailingCity);
                mailPostalCode   = nullToBlank(appForm.Account.PersonMailingPostalCode);
                mailCountryCode  = toIso2Country(appForm.Account.PersonMailingCountry);
            }

            applicant.put('mailing_address', new Map<String, Object>{
                'full'              => '',
                'unit'              => mail.unitNumber,
                'street_number'     => mail.streetNumber,
                'street_name'       => mail.streetName,
                'pobox'             => '',
                'civic_number'      => '',
                'city'              => mailCity,
                'province_code'     => mailProvinceCode,
                'province_other'    => '',
                'postal_code'       => mailPostalCode,
                'Country_code'      => mailCountryCode,
                'other_information' => '',
                'mailing_same_as_home' => boolToInt(sameAsHome),
                'is_mailing'        => 1
            });

            // Keep raw phone format — CFRIMS accepts formatted strings e.g. (514)555-0123
            String primaryPhone   = nullToBlank(appForm.Account.Phone);
            String secondaryPhone = nullToBlank(appForm.Account.PersonOtherPhone);
            Boolean hasSecondary  = String.isNotBlank(secondaryPhone);
            // primary_phone_region / secondary_phone_region need a dial code per CFRIMS                       
            String primaryPhoneRegion =
                String.isNotBlank(appForm.Account.OAP_Primary_Phone_Country_Code__c)
                    ? OAP_PhoneRegionUtil.regionApiName(appForm.Account.OAP_Primary_Phone_Country_Code__c)
                    : 'CAN';
            if (String.isBlank(primaryPhoneRegion)) primaryPhoneRegion = 'CAN';
            String secondaryPhoneRegion = hasSecondary
                ? (String.isNotBlank(appForm.Account.OAP_Other_Phone_Country_Code__c)
                    ? OAP_PhoneRegionUtil.regionApiName(appForm.Account.OAP_Other_Phone_Country_Code__c)
                    : 'CAN')
                : '';
            if (hasSecondary && String.isBlank(secondaryPhoneRegion)) secondaryPhoneRegion = 'CAN';
            applicant.put('phone', new Map<String, Object>{
                'primary_phone'          => primaryPhone,
                'primary_phone_text'     => boolToInt(appForm.Account.OAP_Phone_Text_Agreement__c),
                'primary_phone_ext'      => '',
                'primary_phone_region'   => primaryPhoneRegion,
                'secondary_phone'        => secondaryPhone,
                'secondary_phone_text'   => hasSecondary
                                              ? boolToInt(appForm.Account.OAP_Phone_Text_Agreement__c)
                                              : null,
                'secondary_phone_ext'    => '',
                'secondary_phone_region' => secondaryPhoneRegion
            });
            applicant.put('declaration', new Map<String, Object>{
                // All declaration flags are Nullable<int> on CFRIMS C# side.
                // "Y"/"N" strings caused: "could not be converted to Nullable<int>"
                // Using boolToInt for all three → 0 or 1 (integer)
                'ee_selfDeclaration' => boolToInt(appForm.OAP_Consent_Employment_Equity_Data__c),
                'ee_indigenous'      => boolToInt(appForm.OAP_Self_Identify_Indigenous_Person__c),
                'ee_nonindigenous'   => boolToInt(appForm.OAP_Self_Identify_Visible_Minority__c)
            });
            applicant.put('biography', new Map<String, Object>{
                // All flags are integers 0/1 per new spec
                'foreignMilitaryService'  => boolToInt(appForm.OAP_Prior_Service_in_Foreign_Military__c),
                'criminalConviction'      => boolToInt(appForm.OAP_Criminal_Record_Active_Obligations__c),
                'dualCitizenship'         => boolToInt(appForm.OAP_Citizen_of_Country_other_than_Canada__c),
                'bornOutside'             => boolToInt(appForm.OAP_Born_Outside_Canada__c),
                'lifeOutsideOfCanada'     => boolToInt(appForm.OAP_Outside_Canada_180_Consecutive_Days__c),
                'immediateRelativeOutcan' => boolToInt(appForm.OAP_Immediate_Family_Living_Abroad__c),
                'assetOutsideOfCanada'    => boolToInt(appForm.OAP_Ownership_of_Foreign_Assets__c)
            });
            // career_choice — unified per updated CFRIMS payload spec 
            

            applicant.put('career_choice', new Map<String, Object>{
                'education_level'                    => translateEducationLevel(appForm.OAP_Highest_Level_of_Education__c),
                'parttime_fulltime'                  => translateEmploymentType(appForm.OAP_Employment_Type_Preference__c),
                'preferred_branch_military'          => nullToBlank(appForm.OAP_Preferred_Branch_Military__c),
                //Account.OAP_Unit_Recognition_Code__c was observed
                
                'recognition_code'                   => isLikelyUicCode(appForm.OAP_Unit_Recognition_Code__c)
                    ? appForm.OAP_Unit_Recognition_Code__c : '',
                // Both fields are System.String with valid values "0" or "1" per Abakar spec.
                // "Y"/"N" and blank are rejected by Oracle stored procedure OAPDRS_EXCH.DEX.
                'interested_in_subsidizedEducation'  => boolToInt(appForm.OAP_Interested_in_Subsidized_Education__c),  // Nullable<int> — integer not string
                // v32 fix (Aug 2026): CFRIMS confirmed their published API spec for
               
                'aboriginal_program'                 => String.isNotBlank(appForm.OAP_Indigenous_Program_Options__c) ? 1 : 0,               
                // null when empty per CFRIMS samples (ISP-only applicants have
                // mos:null, non-Indigenous have ISP:null).
                'ISP'                                => ispList.isEmpty() ? null : (Object) ispList,
                'mos'                                => mosList.isEmpty() ? null : (Object) mosList
            });

            // application — consent, dates and signature 
            DateTime submitDt = appForm.SubmissionDate != null
                ? DateTime.newInstance(appForm.SubmissionDate, Time.newInstance(0, 0, 0, 0))
                : DateTime.now();
            applicant.put('application', new Map<String, Object>{
                // consent_application_disclosure from OAP_Consent_Application_Disclosure__c (Boolean → Integer 0/1)
                // Field captures the applicant's explicit consent given during OmniScript submission
                'consent_application_disclosure' => boolToInt(appForm.OAP_Consent_Application_Disclosure__c),
                'consent_date'                   => formatDate(submitDt.date()),
                // conditional_offer_date: generated from submission date when
                // OAP_Consent_Conditional_Enrolment_Offer__c checkbox is checked.
                // Blank string when applicant has not consented to the conditional offer.
                'conditional_offer_date'         => appForm.OAP_Consent_Conditional_Enrolment_Offer__c == true
                                                        ? formatDate(submitDt.date())
                                                        : '',
                'signature'                      => String.isNotBlank(appForm.Application_Signature__c)
                                                        ? appForm.Application_Signature__c
                                                        : (appForm.Account.FirstName + ' '
                                                           + appForm.Account.LastName).trim()
            });
        return applicant;
    }

    //New wrapper for OmniStudio
    public static SubmissionResult submitApplicationFromOmni(Id applicationFormId){
        return submitWithAttempt(applicationFormId, 1);        
    }

    private static SubmissionResult submitWithAttempt(Id applicationFormId, Integer attempt) {
        String LANG = 'E';
        Account acct = new Account();
        ApplicationForm appForm = new ApplicationForm();
        try {
            appForm = [
                SELECT Id,
                        AccountId,
                       SubmissionDate,
                       Application_Signature__c,
                       OAP_Highest_Level_of_Education__c,
                       OAP_Previously_Qualified_CAF_Occupation__c,
                       OAP_Prior_Enrolment_Component_CAF__c,
                       OAP_Preferred_Language_Interview__c,
                       OAP_Preferred_Language_for_Written_Exam__c,
                       OAP_Preferred_Language_Correspondence__c,
                       OAP_Interested_in_Subsidized_Education__c,
                       OAP_Indigenous_Program_Options__c,
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
                       OAP_Employment_Type_Preference__c,
                       OAP_Preferred_Branch_Military__c,
                       Account.FirstName,
                       Account.LastName,
                       Account.PersonBirthdate,
                       Account.OAP_Sex_at_Birth__c,
                       Account.PersonGenderIdentity,
                       Account.OAP_Preferred_Name__c,
                       Account.OAP_Twin_Siblings__c,
                       Account.Primary_Language__c,
                       Account.PersonEmail,
                       Account.Phone,
                       Account.OAP_Phone_Text_Agreement__c,
                       Account.PersonOtherPhone,
                       Account.user_key__pc,
                       Account.CFRIMS_User_Identifier__pc,
                       Account.CFRIMS_Client_Session_Id__pc,
                       Account.CFRIMS_Access_Token__pc,
                       Account.CFRIMS_Sync_Status__pc,
                       Account.OAP_Canadian_Service_Number__c,
                       Account.PersonMailingStreet,
                       Account.PersonMailingCity,
                       Account.PersonMailingState,
                       Account.PersonMailingPostalCode,
                       Account.PersonMailingCountry,
                       Account.OAP_Mailing_is_the_same_as_Residential__c,
                       Account.PersonOtherStreet,
                       Account.PersonOtherCity,
                       Account.PersonOtherState,
                       Account.PersonOtherPostalCode,
                       Account.PersonOtherCountry,
                       Account.OAP_Citizenship__c,
                       Account.Permanent_Resident_Number__c,
                       Account.Permanent_Resident_Effective_Date__c,
                       Account.OAP_Birth_City__c,
                       Account.OAP_Birth_Province_State__c,
                       Account.OAP_Birth_Country__c,
                       OAP_Previous_Service_Number__c,
                       OAP_Interested_Reapply_Prior_Role__c,
                       OAP_Date_Canadian_Citizenship_Granted__c,
                       OAP_Date_Entry_In_Canada__c,
                       OAP_Reserve_Unit_of_Interest__c,
                       OAP_ISP_Options__c,
                       OAP_Unit_Recognition_Code__c,
                       OAP_Permanent_Resident_Number__c,
                       OAP_Consent_Application_Disclosure__c,
                       OAP_Consent_Conditional_Enrolment_Offer__c,
                       Account.OAP_Primary_Phone_Country_Code__c,
                       Account.OAP_Other_Phone_Country_Code__c
                FROM ApplicationForm
                WHERE Id = :applicationFormId
                LIMIT 1
            ];

            if (appForm.AccountId == null) {

                System.debug('OAP_ApplicationFormHandler: AccountId is null on form '
                    + applicationFormId);

                SubmissionResult result = new SubmissionResult();
                result.success = false;
                result.status = 'FAILED';
                result.message = 'Application Form has no Account';
                result.errorCode = 'NO_ACCOUNT';

                return result;
            }            

            acct.Id = appForm.AccountId;

            // Resubmit guard  
           
            if (hasAlreadySynced(applicationFormId)) {
                SubmissionResult result = new SubmissionResult();
                result.success = true;
                result.status = 'SUCCESS';
                result.message = 'Application already submitted';
                result.errorCode = 'null';

                return result;
            }            

            // PersonEmployment — separate query (all records) 
            
            EmploymentContext empCtx = loadEmploymentContext(appForm.AccountId);
            PersonEmployment personEmp = empCtx.personEmp;
            List<Map<String, Object>> cadetsPayload = empCtx.cadetsPayload;           

            // MOS from ApplicationFormRelation → JobPosition 
            List<Map<String, Object>> mosList = buildMosList(applicationFormId);

            Boolean hasMailing =
                String.isNotBlank(appForm.Account.PersonMailingStreet)
                || String.isNotBlank(appForm.Account.PersonMailingCity);
            Boolean hasHome =
                String.isNotBlank(appForm.Account.PersonOtherStreet)
                || String.isNotBlank(appForm.Account.PersonOtherCity);
            if (!hasMailing && !hasHome) {
                acct.CFRIMS_Sync_Status__pc = 'Failed';
                if (acct.Id != null) update acct;

                SubmissionResult result = new SubmissionResult();
                result.success = false;
                result.status = 'FAILED';
                result.message = 'Mailing or home address is required';
                result.errorCode = 'MISSING_ADDRESS';

                return result;
            }

            String email = appForm.Account.PersonEmail;

            // Resolve userIdentifier via Cfrims2HandshakeIdStore 
            String userIdentifier = resolveUserIdentifier(appForm.Account, email);

            //Token reuse with fallback handshake  
            
            TokenResolution tokRes = resolveAccessToken(appForm.Account, userIdentifier, email);
            String accessToken     = tokRes.accessToken;
            String userKey         = tokRes.userKey;
            userIdentifier          = tokRes.userIdentifier;
            Boolean didHandshake    = tokRes.didHandshake;
            String clientSessionId  = tokRes.clientSessionId;

            // ISP — Indigenous Summer Program array  
            List<Map<String, Object>> ispList = buildIspList(appForm.OAP_ISP_Options__c);

            // refined no-occupation warning — ISP-only applicants
            // legitimately have mos:null (per CFRIMS samples), so only warn
            // when the submission carries NEITHER occupations NOR programs.
            if (mosList.isEmpty() && ispList.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    'OAP_ApplicationFormHandler: submission for ' + email
                    + ' has NO occupations and NO ISP programs — CFRIMS will '
                    + 'accept the submit but assign NO default tasks. Verify '
                    + 'front-end validation requires an occupation or program.');
            }

            //  Build applicant payload 
            Map<String, Object> applicant = buildApplicantPayload(
                appForm, personEmp, cadetsPayload, mosList, ispList);


            // ── gatewayBaseRequest REMOVED per Abakar (CFRIMS team) confirmation ──
            
            CFRIMS_Config__mdt config = OAP_Utils.getConfigs();
            // userIdentifier already resolved above from Account field
            String resolvedUserIdentifier = userIdentifier;

            String applicantJson    = JSON.serialize(applicant);
            String encryptedPayload = OAP_CFRIMS_EncryptionService.encrypt(applicantJson);
            String requestBody      = JSON.serialize(new Map<String, String>{
                'EncryptedPayload' => encryptedPayload
            });

            OAP_HttpCalloutGateway.CalloutRequest req =
                OAP_HttpCalloutGateway.buildRequest('Submit');
            req.body = requestBody;
            req.customHeaders = new Map<String, String>{
                'Content-Type'  => 'application/json',
                'Authorization' => 'Bearer ' + accessToken,   // all session info is in this token
                'X-Client-Id'   => config.Client_Id__c,
                'language'      => 'E'
                // X-Client-Assertion removed — not required for submit per spec section 
            };
            HttpResponse res = OAP_HttpCalloutGateway.send(req);

            System.debug(LoggingLevel.Error, 'SFRIMS Submit Status=' +res.getStatusCode());
            System.debug(LoggingLevel.Error, 'CFRIMS Submit Body=' +res.getBody());

            acct.user_key__pc               = userKey;
            acct.CFRIMS_User_Identifier__pc = resolvedUserIdentifier;
            // Persist the fallback-handshake token (v6) so startSession's
            // stored-token path and any subsequent submit reuse THIS session
            // instead of handshaking again.
            if (didHandshake && String.isNotBlank(accessToken)) {
                acct.CFRIMS_Access_Token__pc = accessToken;
            }
            // CFRIMS_Client_Session_Id__pc was never
           
            if (didHandshake && String.isNotBlank(clientSessionId)) {
                acct.CFRIMS_Client_Session_Id__pc = clientSessionId;
            }

            // CFRIMS submit response format (per spec):
            //   {"success": 1, "error": "200", "Message": "Application submitted successfully"}
            // Primary success indicator: success = 1 (integer)
            // Note: "Message" has capital M, "error" is "200" string on success
            Boolean submitSucceeded = (res.getStatusCode() == 200)
                && (res.getBody().contains('"success":1')
                    || res.getBody().contains('"success": 1'));
            if (submitSucceeded) {
                acct.CFRIMS_Sync_Status__pc = 'Success';

                appForm.Stage = 'Submitted';
                appForm.ApplicationStatus = 'Submitted';

                CFRIMS_Logger.CFRIMSlogAPI(
                    'submitApplicant', config.API_Base_URL__c + '/Applicants/submit',
                    'POST', applicantJson, res.getBody(),
                    res.getStatusCode(), true, null,
                    String.valueOf(appForm.AccountId), String.valueOf(appForm.Id));
            } else {
                acct.CFRIMS_Sync_Status__pc = 'Failed';
                appForm.ApplicationStatus = 'Pending Submission';
                CFRIMS_Logger.CFRIMSlogAPI(
                    'submitApplicant', config.API_Base_URL__c + '/Applicants/submit',
                    'POST', applicantJson, res.getBody(),
                    res.getStatusCode(), false, 'Submit failed: ' + res.getStatusCode(),
                    String.valueOf(appForm.AccountId), String.valueOf(appForm.Id));                
               
                String respBody = res.getBody() == null ? '' : res.getBody();
                Boolean transientFailure =
                    res.getStatusCode() >= 500
                    || respBody.contains('Database failed to process');
                if (transientFailure && attempt < MAX_SUBMIT_ATTEMPTS) {
                    System.debug(LoggingLevel.WARN,
                        'OAP_ApplicationFormHandler: transient CFRIMS failure on attempt '
                        + attempt + ' — scheduling retry ' + (attempt + 1)
                        + ' in ' + RETRY_DELAY_MINUTES + ' min.');
                    if (!Test.isRunningTest()) {
                        System.enqueueJob(
                            new SubmitRetryJob(applicationFormId, attempt + 1),
                            RETRY_DELAY_MINUTES);
                    }
                }
                
            }

            // All callouts complete — flush persist + logs before DML 
           
            try { Cfrims2HandshakeIdStore.flushPersist(); }
            catch (Exception fpEx) { System.debug('[sendApplicationToCFRIMS] flushPersist: ' + fpEx.getMessage()); }
            try { CFRIMS_Logger.flush(); }
            catch (Exception logEx) { System.debug('[sendApplicationToCFRIMS] Logger.flush: ' + logEx.getMessage()); }
            update acct;   

            if(submitSucceeded || appForm.ApplicationStatus == 'Pending Submission') {
                update appForm;
            }

            if (submitSucceeded) {
                
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new OAP_Cfrims2DashboardFetcher(
                        appForm.AccountId, appForm.Id, email
                    ));
                }
            }

        } catch (Exception e) {
            String msg = e.getMessage() == null ? '' : e.getMessage();
            Boolean isDuplicateEmail =
                msg.contains('UK_EMAIL')
                || msg.contains('ORA-00001')
                || msg.containsIgnoreCase('unique constraint');

            if (isDuplicateEmail) {
                acct.CFRIMS_Sync_Status__pc = 'Already Registered';
            } else {
                acct.CFRIMS_Sync_Status__pc = 'Failed';
                appForm.ApplicationStatus = 'Pending Submission';
            }

            // Flush before DML in catch block — wrapped independently
            try { Cfrims2HandshakeIdStore.flushPersist(); }
            catch (Exception fpEx) { System.debug('[sendApplicationToCFRIMS] catch flushPersist: ' + fpEx.getMessage()); }
            try { CFRIMS_Logger.flush(); }
            catch (Exception logEx) { System.debug('[sendApplicationToCFRIMS] catch Logger.flush: ' + logEx.getMessage()); }

            if (acct.Id != null) update acct;

            if(appForm.ApplicationStatus == 'Pending Submission'){
                update appForm;
            }

            CFRIMS_Logger.CFRIMSlogAPI(
                'submitApplicant', '', 'POST', '', msg,
                null, false,
                isDuplicateEmail ? 'Already Registered' : 'Submit failed: ' + msg,
                acct.Id != null ? String.valueOf(acct.Id) : null,
                acct.Id != null ? String.valueOf(acct.Id) : null
            );
            CFRIMS_Logger.flush();
        }

        SubmissionResult result = new SubmissionResult();
                result.success = (acct.CFRIMS_Sync_Status__pc == 'Success');
                result.status = result.success ? 'SUCCESS' : 'FAILED';
                result.message = result.success
                    ? 'Submission completed successfully'
                    : 'Submission failed';
                result.errorCode = result.success ? null : 'SUBMISSION_FAILED';

                return result;
    }

    @TestVisible private static String translateEmploymentType(String sfValue) {
        if (String.isBlank(sfValue)) return '';
        // CONFIRMED values from CFRIMS career_choice samples (24-Jul):
        // "REG F" and "RES F" — space-separated, NOT underscore codes.
        // (Previous REG_F/RESERVE/PT values were wrong.)
        if (sfValue == 'REG F' || sfValue == 'Regular Force' || sfValue == 'Full Time'
            || sfValue == 'Fulltime' || sfValue == 'FullTime') return 'REG F';
        if (sfValue == 'RES F' || sfValue == 'Reserve Forces' || sfValue == 'Reserve'
            || sfValue == 'Part Time' || sfValue == 'PartTime') return 'RES F';
        return sfValue;
    }
    @TestVisible private static String translateEducationLevel(String sfValue) {
        if (String.isBlank(sfValue)) return '';
        // Map Salesforce picklist labels → CFRIMS education_level codes.
        // ️ CONFIRM these labels match your org's OAP_Highest_Level_of_Education__c picklist.
        if (sfValue.contains('Bachelor'))     return 'Bachelor';
        if (sfValue.contains('Master'))       return 'Master';
        if (sfValue.contains('Doctoral') || sfValue.contains('PhD') || sfValue.contains('Ph.D')) return 'Doctoral';
        if (sfValue.contains('College') || sfValue.contains('Diploma')) return 'College';
        if (sfValue.contains('High School') || sfValue.contains('Secondary')) return 'HighSchool';
        if (sfValue.contains('Trade') || sfValue.contains('Vocational') || sfValue.contains('Apprentice')) return 'Trade';
        if (sfValue.contains('Some University') || sfValue.contains('Some College')) return 'SomeUniversity';
        return sfValue; // pass through if no match — flag in logs if CFRIMS rejects
    }
    @TestVisible private static String translateSex(String sfValue) {
        if (String.isBlank(sfValue)) return '';
        if (sfValue == 'Male')     return 'M';
        if (sfValue == 'Female')   return 'F';
        if (sfValue == 'Intersex') return 'I';
        return '';
    }
    @TestVisible private static String translateGender(String sfValue) {
        if (String.isBlank(sfValue)) return '';
        if (sfValue == 'Man')            return 'M';
        if (sfValue == 'Woman')          return 'F';
        if (sfValue == 'Gender Diverse') return 'I';
        return '';
    }
    @TestVisible private static String translateLanguageToCode(String sfValue) {
        if (String.isBlank(sfValue)) return 'E';
        if (sfValue.equalsIgnoreCase('French'))  return 'F';
        if (sfValue.equalsIgnoreCase('English')) return 'E';
        if (sfValue.equalsIgnoreCase('F')) return 'F';
        if (sfValue.equalsIgnoreCase('E')) return 'E';
        return 'E';
    }
    @TestVisible private static String translateCountryToCode(String sfValue) {
        if (String.isBlank(sfValue)) return '';
        String v = sfValue.trim();
        String vUpper = v.toUpperCase();
        if (vUpper == 'CANADA' || vUpper == 'CA' || vUpper == 'CAN') return 'CAN';
        if (vUpper == 'UNITED STATES' || vUpper == 'USA' || vUpper == 'US') return 'USA';
        return vUpper.length() == 3 ? vUpper : v;
    }
    @TestVisible private static String boolToFlag(Boolean b) {
        return (b != null && b) ? '1' : '0';
    }
    @TestVisible private static String boolToFlag(String s) {
        if (String.isBlank(s)) return '0';
        String v = s.trim().toLowerCase();
        if (v == '1' || v == 'true' || v == 'yes' || v == 'y') return '1';
        return '0';
    }
    // Canadian-citizen indicator from Account.OAP_Citizenship__c. Accepts
    // both boolean-style answers and citizenship-status picklist values.
    @TestVisible private static Integer isCanadianCitizen(String s) {
        if (String.isBlank(s)) return 0;
        String v = s.trim().toLowerCase();
        if (v == '1' || v == 'true' || v == 'yes' || v == 'y') return 1;
        if (isPermanentResident(s) == 1) return 0;
        return v.contains('canadian') ? 1 : 0;
    }
    // Permanent-resident indicator from the Account.OAP_Citizenship__c
    // citizenship-status picklist (e.g. "Permanent Resident").
    @TestVisible private static Integer isPermanentResident(String s) {
        if (String.isBlank(s)) return 0;
        String v = s.trim().toLowerCase();
        return (v.contains('permanent') || v == 'pr') ? 1 : 0;
    }
    /**
     * Mailing is "same as home" when the applicant supplied no distinct
     * mailing address, or the mailing fields match the residential
     * (PersonOther*) fields. Derived from the address data itself rather
     * than the OAP_Mailing_is_the_same_as_Residential__c checkbox, so a
     * mis-mapped flag can never oust a real mailing address or flip the
     * CFRIMS "Same as Home Address" toggle.
     */
    @TestVisible
    private static Boolean isMailingSameAsHome(Account acct) {
        Boolean mailingProvided =
            String.isNotBlank(acct.PersonMailingStreet)
            || String.isNotBlank(acct.PersonMailingCity)
            || String.isNotBlank(acct.PersonMailingPostalCode);
        if (!mailingProvided) return true;
        return normalizeAddr(acct.PersonMailingStreet) == normalizeAddr(acct.PersonOtherStreet)
            && normalizeAddr(acct.PersonMailingCity) == normalizeAddr(acct.PersonOtherCity)
            && normalizeAddr(acct.PersonMailingPostalCode) == normalizeAddr(acct.PersonOtherPostalCode);
    }

    private static String normalizeAddr(String s) {
        return String.isBlank(s) ? '' : s.trim().toUpperCase().replaceAll('\\s+', ' ');
    }

    @TestVisible private static Integer boolToInt(Boolean b) { return (b != null && b) ? 1 : 0; }
    @TestVisible private static Integer boolToInt(String s) {
        if (String.isBlank(s)) return 0;
        String v = s.trim().toLowerCase();
        return (v == '1' || v == 'true' || v == 'yes' || v == 'y') ? 1 : 0;
    }
   
    @TestVisible private static String formatDate(Date d) {
        if (d == null) return '';
        return String.valueOf(d.year()).leftPad(4, '0') + '-'
            + String.valueOf(d.month()).leftPad(2, '0') + '-'
            + String.valueOf(d.day()).leftPad(2, '0');
    }
    @TestVisible private static String formatDateTime(DateTime dt) {
        if (dt == null) return '';
        return dt.format('yyyy-MM-dd HH:mm:ss');
    }
    private static String nullToBlank(String s) {
        return String.isBlank(s) ? '' : s;
    }

    //rejects known non-UIC sentinel values (Yes/No answer text leaking   
    @TestVisible
    private static Boolean isLikelyUicCode(String s) {
        if (String.isBlank(s)) return false;
        String normalized = s.trim().toLowerCase();
        return normalized != 'no' && normalized != 'yes'
            && normalized != 'n/a' && normalized != 'none';
    }
    private static String firstNonBlank(String a, String b) {
        if (String.isNotBlank(a)) return a;
        if (String.isNotBlank(b)) return b;
        return '';
    }
    private static String digitsOnly(String s) {
        return String.isBlank(s) ? '' : s.replaceAll('[^0-9]', '');
    }
    private static String generateSfGuid() {
        return 'SF-GUID-' + String.valueOf(Math.abs(Crypto.getRandomLong()));
    }

    // Token expiry logic is centralised in OAP_CfrimsSessionUtil.
    @TestVisible private static Boolean isTokenExpired(String jwt) {
        return OAP_CfrimsSessionUtil.isTokenExpired(jwt);
    }

    // ── boolToYN — "Y"/"N" per new CFRIMS spec ──────────────────────────────
    // Used for declaration ee_indigenous/ee_nonindigenous and career_choice fields.
    @TestVisible private static String boolToYN(Boolean b) {
        return (b != null && b) ? 'Y' : 'N';
    }
    @TestVisible private static String boolToYN(String s) {
        if (String.isBlank(s)) return 'N';
        String v = s.trim().toLowerCase();
        return (v == '1' || v == 'true' || v == 'yes' || v == 'y') ? 'Y' : 'N';
    }
    @TestVisible private static String boolToYN(Object o) {
        if (o == null) return 'N';
        if (o instanceof Boolean) return boolToYN((Boolean) o);
        return boolToYN(String.valueOf(o));
    }

    // ── toIso2Country — 2-char ISO country code per new CFRIMS spec 
   
    @TestVisible private static String toIso2Country(String country) {
        if (String.isBlank(country)) return '';

        String key = country.trim().toUpperCase();

        // Already a valid-looking ISO2 code — pass through uppercased.
        if (COUNTRY_ISO2_SET.contains(key)) return key;

        // Label or ISO3 alias lookup.
        if (COUNTRY_NAME_TO_ISO2.containsKey(key)) {
            return COUNTRY_NAME_TO_ISO2.get(key);
        }

        // Unmapped — log for follow-up instead of shipping bad data to CFRIMS.
        System.debug(LoggingLevel.WARN,
            'OAP_ApplicationFormHandler.toIso2Country: unmapped country value "'
            + country + '" — sending blank Country_code. Add this value to '
            + 'COUNTRY_NAME_TO_ISO2 if it is a legitimate country label/alias.');
        return '';
    }

    // ── toDialCode — phone region as a calling code per CFRIMS spec    
    @TestVisible private static String toDialCode(String rawPhoneRegionValue) {
        return OAP_PhoneRegionUtil.extractDialCode(rawPhoneRegionValue);
    }

    // ── Lookup tables for toIso2Country() ────────────────────────────────
    // Keys are always uppercase for case-insensitive matching above.   
    private static final Set<String> COUNTRY_ISO2_SET = new Set<String>{
        'AD','AE','AF','AG','AI','AL','AM','AO','AR','AT','AU','AW','AZ',
        'BA','BB','BD','BE','BF','BG','BH','BI','BJ','BN','BO','BR','BS','BT','BW','BY','BZ',
        'CA','CD','CF','CG','CH','CI','CL','CM','CN','CO','CR','CU','CV','CY','CZ',
        'DE','DJ','DK','DM','DO','DZ',
        'EC','EE','EG','ER','ES','ET',
        'FI','FJ','FM','FR',
        'GA','GB','GD','GE','GH','GM','GN','GQ','GR','GT','GW','GY',
        'HK','HN','HR','HT','HU',
        'ID','IE','IL','IN','IQ','IR','IS','IT',
        'JM','JO','JP',
        'KE','KG','KH','KI','KM','KN','KP','KR','KW','KZ',
        'LA','LB','LC','LI','LK','LR','LS','LT','LU','LV','LY',
        'MA','MC','MD','ME','MG','MH','MK','ML','MM','MN','MR','MT','MU','MV','MW','MX','MY','MZ',
        'NA','NE','NG','NI','NL','NO','NP','NR','NZ',
        'OM',
        'PA','PE','PG','PH','PK','PL','PT','PW','PY',
        'QA',
        'RO','RS','RU','RW',
        'SA','SB','SC','SD','SE','SG','SI','SK','SL','SM','SN','SO','SR','SS','ST','SV','SY','SZ',
        'TD','TG','TH','TJ','TL','TM','TN','TO','TR','TT','TV','TW','TZ',
        'UA','UG','US','UY','UZ',
        'VA','VC','VE','VN','VU',
        'WS',
        'YE',
        'ZA','ZM','ZW'
    };

    private static final Map<String, String> COUNTRY_NAME_TO_ISO2 = new Map<String, String>{
        // North America
        'CANADA' => 'CA', 'CAN' => 'CA',
        'UNITED STATES' => 'US', 'UNITED STATES OF AMERICA' => 'US', 'USA' => 'US', 'U.S.A.' => 'US',
        'MEXICO' => 'MX', 'MEX' => 'MX',
        // Common CAF-applicant countries of origin (extend as unmapped values surface
        // in the WARN debug logs from toIso2Country() above)
        'UNITED KINGDOM' => 'GB', 'GBR' => 'GB', 'GREAT BRITAIN' => 'GB',
        'FRANCE' => 'FR', 'FRA' => 'FR',
        'GERMANY' => 'DE', 'DEU' => 'DE',
        'AUSTRALIA' => 'AU', 'AUS' => 'AU',
        'NEW ZEALAND' => 'NZ', 'NZL' => 'NZ',
        'INDIA' => 'IN', 'IND' => 'IN',
        'PHILIPPINES' => 'PH', 'PHL' => 'PH',
        'NIGERIA' => 'NG', 'NGA' => 'NG',
        'JAMAICA' => 'JM', 'JAM' => 'JM',
        'HAITI' => 'HT', 'HTI' => 'HT',
        'CHINA' => 'CN', 'CHN' => 'CN',
        'SOUTH KOREA' => 'KR', 'KOREA, SOUTH' => 'KR', 'REPUBLIC OF KOREA' => 'KR',
        'VIETNAM' => 'VN', 'VNM' => 'VN',
        'UKRAINE' => 'UA', 'UKR' => 'UA',
        'POLAND' => 'PL', 'POL' => 'PL',
        'ZIMBABWE' => 'ZW', 'ZWE' => 'ZW',
        'NICARAGUA' => 'NI', 'NIC' => 'NI',
        'SOUTH AFRICA' => 'ZA', 'ZAF' => 'ZA',
        'PAKISTAN' => 'PK', 'PAK' => 'PK',
        'BANGLADESH' => 'BD', 'BGD' => 'BD',
        'BRAZIL' => 'BR', 'BRA' => 'BR',
        'COLOMBIA' => 'CO', 'COL' => 'CO'
    };
}