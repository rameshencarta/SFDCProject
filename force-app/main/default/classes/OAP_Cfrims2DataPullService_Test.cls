@isTest
private class OAP_Cfrims2DataPullService_Test {
  private static final String SUCCESS_EMAIL = 'datapull.success@example.invalid';
  private static final String FAILURE_EMAIL = 'datapull.failure@example.invalid';

  private class DashboardPullMock implements HttpCalloutMock {
    Integer statusCode;
    String body;

    DashboardPullMock(Integer statusCode, String body) {
      this.statusCode = statusCode;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(statusCode);
      res.setStatus(statusCode == 200 ? 'OK' : 'Server Error');
      res.setBody(body);
      return res;
    }
  }

  @testSetup
  static void setupData() {
    Account successAcct = OAP_TestUtil.createPersonAccount('Test', SUCCESS_EMAIL);
    OAP_CfrimsTestSupport.createApplicationForm(successAcct.Id);
    OAP_TestUtil.createPersonAccount('Test', FAILURE_EMAIL);
  }

  @isTest
  static void pull_blankEmail_skipsWork() {
    Test.startTest();
    OAP_Cfrims2DataPullService.pull(null);
    OAP_Cfrims2DataPullService.pull(' ');
    Test.stopTest();

    System.assert(true, 'Blank email should not throw');
  }

  @isTest
  static void pull_withoutSession_throwsClearException() {
    Boolean thrown = false;
    try {
      OAP_Cfrims2DataPullService.pull('nosession@example.invalid');
    } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception ex) {
      thrown = true;
      System.assert(ex.getMessage().contains('No active CFRIMS session'));
    }
    System.assert(thrown, 'Expected missing session to throw');
  }

  @isTest
  static void pull_success_updatesAccountAndApplicationForm() {
    Account acct = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :SUCCESS_EMAIL
      LIMIT 1
    ];
    ApplicationForm existing = [
      SELECT Id
      FROM ApplicationForm
      WHERE AccountId = :acct.Id
      LIMIT 1
    ];
    Map<String, String> handshake = baseHandshake(acct.PersonEmail);
    handshake.put('rawBody', richHandshakeBody());
    OAP_Cfrims2SessionCache.putHandshake(UserInfo.getUserId(), handshake);
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, richDashboardBody(acct.PersonEmail))
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(acct.PersonEmail);
    Test.stopTest();

    Account updated = [
      SELECT
        FirstName,
        LastName,
        CFRIMS_Alpha_Number__pc,
        OAP_Canadian_Service_Number__c,
        CFRIMS_Sync_Status__pc,
        CFRIMS_Last_Dashboard_Sync__pc,
        CFRIMS_Applicant_Status__pc,
        CFRIMS_Applicant_File_Status__pc,
        PersonGenderIdentity,
        OAP_Sex_at_Birth__c,
        Phone,
        PersonOtherPhone,
        PersonMailingCity,
        PersonOtherCity,
        user_key__pc,
        CFRIMS_User_Identifier__pc
      FROM Account
      WHERE Id = :acct.Id
    ];
    System.assertEquals('Pat', updated.FirstName);
    System.assertEquals('Applicant', updated.LastName);
    System.assertEquals('A-DATA-1', updated.CFRIMS_Alpha_Number__pc);
    System.assertEquals('PSN-1', updated.OAP_Canadian_Service_Number__c);
    System.assertEquals('Success', updated.CFRIMS_Sync_Status__pc);
    System.assertNotEquals(null, updated.CFRIMS_Last_Dashboard_Sync__pc);
    // Restricted picklist: the API name (M), never the label (Man)
    System.assertEquals('M', updated.PersonGenderIdentity);
    System.assertEquals('Male', updated.OAP_Sex_at_Birth__c);
    System.assertEquals('6135551111', updated.Phone);
    System.assertEquals('6135552222', updated.PersonOtherPhone);
    System.assertEquals('Ottawa', updated.PersonMailingCity);
    System.assertEquals('Kingston', updated.PersonOtherCity);
    System.assertEquals('USERKEY-DATA', updated.user_key__pc);
    System.assertEquals('UID-DATA', updated.CFRIMS_User_Identifier__pc);
    // Raw CFRIMS status codes land on the Account unmapped
    System.assertEquals('10', updated.CFRIMS_Applicant_Status__pc);
    System.assertEquals('6', updated.CFRIMS_Applicant_File_Status__pc);

    ApplicationForm form = [
      SELECT Id, Stage, ApplicationStatus, CFRIMS_Synced__c,
        OAP_Highest_Level_of_Education__c,
        OAP_Occupation_Display__c, Occupation_Display_Component__c
      FROM ApplicationForm
      WHERE Id = :existing.Id
    ];
    System.assertEquals(existing.Id, form.Id);
    System.assertEquals('Draft', form.Stage);
    System.assertEquals('Draft', form.ApplicationStatus);
    System.assertEquals(true, form.CFRIMS_Synced__c);
    System.assertEquals(1, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acct.Id],
      'opened_for_reapply=0 must not create a reapply Draft');
    System.assertEquals('INF, ARTY', form.OAP_Occupation_Display__c);
    System.assertEquals('REG F', form.Occupation_Display_Component__c);
    System.assertEquals(
      OAP_Cfrims2DataPullService.educationApiName('bachelor'),
      form.OAP_Highest_Level_of_Education__c,
      'Education must persist as a valid picklist API name'
    );
  }

  @isTest
  static void pull_dashboardFailure_throwsCfrimsException() {
    Account acct = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :FAILURE_EMAIL
      LIMIT 1
    ];
    OAP_Cfrims2SessionCache.putHandshake(
      UserInfo.getUserId(),
      baseHandshake(acct.PersonEmail)
    );
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(503, '{"error":"down"}')
    );

    Test.startTest();
    Boolean thrown = false;
    try {
      OAP_Cfrims2DataPullService.pull(acct.PersonEmail);
    } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception ex) {
      thrown = true;
      System.assert(ex.getMessage().contains('Dashboard pull failed'));
    }
    Test.stopTest();

    System.assert(thrown, 'Expected dashboard failure to throw');

    Account untouched = [
      SELECT CFRIMS_Alpha_Number__pc, CFRIMS_Last_Dashboard_Sync__pc
      FROM Account
      WHERE Id = :acct.Id
    ];
    System.assertEquals(
      null,
      untouched.CFRIMS_Alpha_Number__pc,
      'Failed pull must not write Account data'
    );
    System.assertEquals(
      null,
      untouched.CFRIMS_Last_Dashboard_Sync__pc,
      'Failed pull must not stamp a sync time'
    );
  }

  @isTest
  static void pull_malformedDashboard_returnsWithoutThrowing() {
    Account acct = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :FAILURE_EMAIL
      LIMIT 1
    ];
    OAP_Cfrims2SessionCache.putHandshake(
      UserInfo.getUserId(),
      baseHandshake(acct.PersonEmail)
    );
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, '{bad json')
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(acct.PersonEmail);
    Test.stopTest();

    Account untouched = [
      SELECT CFRIMS_Alpha_Number__pc, CFRIMS_Last_Dashboard_Sync__pc
      FROM Account
      WHERE Id = :acct.Id
    ];
    System.assertEquals(
      null,
      untouched.CFRIMS_Alpha_Number__pc,
      'Malformed dashboard JSON must not write Account data'
    );
    System.assertEquals(
      null,
      untouched.CFRIMS_Last_Dashboard_Sync__pc,
      'Malformed dashboard JSON must not stamp a sync time'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM ApplicationForm
        WHERE AccountId = :acct.Id
      ],
      'Malformed dashboard JSON must not create an ApplicationForm'
    );
  }

  @isTest
  static void pull_noMatchingAccount_skipsAfterDashboardParse() {
    String email = 'datapull.noaccount@example.invalid';
    OAP_Cfrims2SessionCache.putHandshake(
      UserInfo.getUserId(),
      baseHandshake(email)
    );
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, richDashboardBody(email))
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(email);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Account WHERE PersonEmail = :email]
    );
  }

  @isTest
  static void pull_badHandshakeRawBody_stillProcessesDashboard() {
    Account acct = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :FAILURE_EMAIL
      LIMIT 1
    ];
    Map<String, String> handshake = baseHandshake(acct.PersonEmail);
    handshake.put('rawBody', '{bad handshake json');
    OAP_Cfrims2SessionCache.putHandshake(UserInfo.getUserId(), handshake);
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, richDashboardBody(acct.PersonEmail))
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(acct.PersonEmail);
    Test.stopTest();

    Account updated = [
      SELECT CFRIMS_Alpha_Number__pc, CFRIMS_Sync_Status__pc
      FROM Account
      WHERE Id = :acct.Id
    ];
    System.assertEquals('A-DATA-1', updated.CFRIMS_Alpha_Number__pc);
    System.assertEquals('Success', updated.CFRIMS_Sync_Status__pc);
  }

  @isTest
  static void pull_duplicateEmails_syncsOldestAccount() {
    Account original = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :FAILURE_EMAIL
      LIMIT 1
    ];
    OAP_CfrimsTestSupport.createPersonAccount(FAILURE_EMAIL);

    Map<String, String> handshake = baseHandshake(original.PersonEmail);
    handshake.put('rawBody', richHandshakeBody());
    OAP_Cfrims2SessionCache.putHandshake(UserInfo.getUserId(), handshake);
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, richDashboardBody(original.PersonEmail))
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(original.PersonEmail);
    Test.stopTest();

    Account updated = [
      SELECT CFRIMS_Alpha_Number__pc
      FROM Account
      WHERE Id = :original.Id
    ];
    System.assertEquals(
      'A-DATA-1',
      updated.CFRIMS_Alpha_Number__pc,
      'Duplicates should resolve deterministically to the oldest Account'
    );
  }

  @isTest
  static void pullAsync_badInputDoesNotThrow() {
    Test.startTest();
    OAP_Cfrims2DataPullService.pullAsync(null, null);
    OAP_Cfrims2DataPullService.pullAsync(
      'badjson@example.invalid',
      '{not json'
    );
    Test.stopTest();

    System.assert(true, 'Bad async input should be swallowed');
  }

  @isTest
  static void pullAsync_dashboardFailureIsCaught() {
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(503, '{"error":"down"}')
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pullAsync(
      'async.failure@example.invalid',
      JSON.serialize(baseHandshake('async.failure@example.invalid'))
    );
    Test.stopTest();

    System.assert(true, 'Async dashboard failures should be caught');
  }

  @isTest
  static void pullAsync_successPathPersistsData() {
    Account acct = [
      SELECT Id, PersonEmail
      FROM Account
      WHERE PersonEmail = :SUCCESS_EMAIL
      LIMIT 1
    ];
    Map<String, String> handshake = baseHandshake(acct.PersonEmail);
    handshake.put('rawBody', richHandshakeBody());
    Test.setMock(
      HttpCalloutMock.class,
      new DashboardPullMock(200, richDashboardBody(acct.PersonEmail))
    );

    Test.startTest();
    OAP_Cfrims2DataPullService.pullAsync(
      acct.PersonEmail,
      JSON.serialize(handshake)
    );
    Test.stopTest();

    Account updated = [
      SELECT CFRIMS_Alpha_Number__pc, CFRIMS_Sync_Status__pc
      FROM Account
      WHERE Id = :acct.Id
    ];
    System.assertEquals('A-DATA-1', updated.CFRIMS_Alpha_Number__pc);
    System.assertEquals('Success', updated.CFRIMS_Sync_Status__pc);
  }

  @isTest
  static void helperMethods_coverNullAndMappingBranches() {
    ApplicationForm form = [
      SELECT Id
      FROM ApplicationForm
      WHERE Account.PersonEmail = :SUCCESS_EMAIL
      LIMIT 1
    ];

    System.assertEquals(
      null,
      OAP_Cfrims2DataPullService.findOrCreateEvaluation(null)
    );
    Id firstEvaluationId = OAP_Cfrims2DataPullService.findOrCreateEvaluation(
      form.Id
    );
    System.assertNotEquals(
      null,
      firstEvaluationId,
      'Evaluation should be created for a valid form'
    );
    System.assertEquals(
      firstEvaluationId,
      OAP_Cfrims2DataPullService.findOrCreateEvaluation(form.Id),
      'Second call must reuse the existing evaluation'
    );

    System.assertEquals('Male', OAP_Cfrims2DataPullService.translateSex('m'));
    System.assertEquals('Female', OAP_Cfrims2DataPullService.translateSex('F'));
    System.assertEquals(
      null,
      OAP_Cfrims2DataPullService.translateSex('unknown')
    );

    // Gender must map to restricted-picklist API names (M/W/D), never labels
    System.assertEquals('M', OAP_Cfrims2DataPullService.translateGender('male'));
    System.assertEquals('M', OAP_Cfrims2DataPullService.translateGender('Man'));
    System.assertEquals('W', OAP_Cfrims2DataPullService.translateGender('woman'));
    System.assertEquals('W', OAP_Cfrims2DataPullService.translateGender('F'));
    System.assertEquals(
      'D',
      OAP_Cfrims2DataPullService.translateGender('non-binary')
    );
    System.assertEquals(
      'D',
      OAP_Cfrims2DataPullService.translateGender('X')
    );
    System.assertEquals(
      null,
      OAP_Cfrims2DataPullService.translateGender('unknown')
    );

    System.assert(
      OAP_Cfrims2DataPullService.dashboardEndpointForLog()
        .endsWith('/Applicants/dashboard'),
      'Log endpoint must target the dashboard path on the configured base URL'
    );

    // Education mapping only ever returns valid picklist API names
    Set<String> validEdu = new Set<String>();
    for (
      Schema.PicklistEntry pe : ApplicationForm.OAP_Highest_Level_of_Education__c.getDescribe()
        .getPicklistValues()
    ) {
      validEdu.add(pe.getValue());
    }
    String mappedBachelor = OAP_Cfrims2DataPullService.educationApiName(
      'bachelor'
    );
    System.assertNotEquals(
      null,
      mappedBachelor,
      'bachelor should resolve to a picklist API name'
    );
    System.assert(
      validEdu.contains(mappedBachelor),
      'Mapped education value must be a valid API name: ' + mappedBachelor
    );
    System.assertEquals(
      null,
      OAP_Cfrims2DataPullService.educationApiName('not-a-real-level'),
      'Unknown education values must be rejected, not sent to DML'
    );
  }

  // ── Re-apply (opened_for_reapply) ─────────────────────────────────────

  @isTest
  static void parseHandshakeReapplyFlag_coversNumericBooleanAndMissing() {
    System.assertEquals(true,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag('{"opened_for_reapply":1}'));
    System.assertEquals(true,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag('{"opened_for_reapply":true}'));
    System.assertEquals(false,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag('{"opened_for_reapply":0}'));
    System.assertNotEquals(true,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag('{"require_merge":0}'),
      'Missing flag must never read as re-apply');
    System.assertNotEquals(true,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag('not-json'));
    System.assertNotEquals(true,
      OAP_Cfrims2DataPullService.parseHandshakeReapplyFlag(null));
  }

  @isTest
  static void cfrimsSyncedFormId_prefersNewestNonDraftOverReapplyDraft() {
    Account acct = [SELECT Id FROM Account WHERE PersonEmail = :SUCCESS_EMAIL LIMIT 1];
    ApplicationForm submitted = [
      SELECT Id FROM ApplicationForm WHERE AccountId = :acct.Id LIMIT 1
    ];
    submitted.Stage = 'Submitted';
    submitted.CFRIMS_Synced__c = true;
    update submitted;

    Test.startTest();
    Id draftId = OAP_Cfrims2DataPullService.ensureReapplyDraft(acct.Id, submitted.Id);
    Id syncedId = OAP_Cfrims2DataPullService.cfrimsSyncedFormId(acct.Id);
    Test.stopTest();

    System.assertNotEquals(null, draftId, 'A reapply Draft must be created');
    System.assertNotEquals(submitted.Id, draftId, 'The Draft must be a new form');
    System.assertEquals(submitted.Id, syncedId,
      'CFRIMS data must keep targeting the submitted form, never the reapply Draft');
    System.assertEquals(null, OAP_Cfrims2DataPullService.cfrimsSyncedFormId(null));
  }

  @isTest
  static void ensureReapplyDraft_prefillsAndReusesExistingDraft() {
    Account acct = [SELECT Id FROM Account WHERE PersonEmail = :SUCCESS_EMAIL LIMIT 1];
    ApplicationForm closed = [
      SELECT Id, UsageType FROM ApplicationForm WHERE AccountId = :acct.Id LIMIT 1
    ];
    closed.Stage = 'Submitted';
    closed.CFRIMS_Synced__c = true;
    closed.OAP_Interested_Reapply_Prior_Role__c = 'Yes';
    update closed;

    Test.startTest();
    Id first = OAP_Cfrims2DataPullService.ensureReapplyDraft(acct.Id, closed.Id);
    Id second = OAP_Cfrims2DataPullService.ensureReapplyDraft(acct.Id, closed.Id);
    Test.stopTest();

    System.assertEquals(first, second,
      'A repeat login must reuse the unsynced Draft, not create a second one');
    System.assertEquals(2, [SELECT COUNT() FROM ApplicationForm WHERE AccountId = :acct.Id]);

    ApplicationForm draft = [
      SELECT Stage, ApplicationStatus, CFRIMS_Synced__c, UsageType,
        OAP_Interested_Reapply_Prior_Role__c
      FROM ApplicationForm WHERE Id = :first
    ];
    System.assertEquals('Draft', draft.Stage);
    System.assertEquals('Draft', draft.ApplicationStatus);
    System.assertEquals(false, draft.CFRIMS_Synced__c);
    System.assertEquals(closed.UsageType, draft.UsageType);
    System.assertEquals('Yes', draft.OAP_Interested_Reapply_Prior_Role__c,
      'Prior answers must be carried into the reapply Draft');

    ApplicationForm history = [SELECT Stage FROM ApplicationForm WHERE Id = :closed.Id];
    System.assertEquals('Submitted', history.Stage, 'The closed form must stay as history');

    System.assertEquals(null, OAP_Cfrims2DataPullService.ensureReapplyDraft(null, closed.Id));
  }

  @isTest
  static void pull_openedForReapply_createsDraftAndProtectsSubmittedForm() {
    Account acct = [SELECT Id, PersonEmail FROM Account WHERE PersonEmail = :SUCCESS_EMAIL LIMIT 1];
    ApplicationForm closed = [SELECT Id FROM ApplicationForm WHERE AccountId = :acct.Id LIMIT 1];
    closed.Stage = 'Submitted';
    closed.CFRIMS_Synced__c = true;
    update closed;

    Map<String, String> handshake = baseHandshake(acct.PersonEmail);
    handshake.put('rawBody', '{"opened_for_reapply":1,"application_completed":1,"applicant_data":{}}');
    OAP_Cfrims2SessionCache.putHandshake(UserInfo.getUserId(), handshake);
    Map<String, Object> dashboard = (Map<String, Object>) JSON.deserializeUntyped(
      richDashboardBody(acct.PersonEmail));
    dashboard.put('applications', new List<Object>{
      new Map<String, Object>{ 'application_completed' => 1, 'submission_date' => '2026-08-01' }
    });
    Test.setMock(HttpCalloutMock.class,
      new DashboardPullMock(200, JSON.serialize(dashboard)));

    Test.startTest();
    OAP_Cfrims2DataPullService.pull(acct.PersonEmail);
    Test.stopTest();

    List<ApplicationForm> forms = [
      SELECT Id, Stage, CFRIMS_Synced__c, OAP_Occupation_Display__c
      FROM ApplicationForm WHERE AccountId = :acct.Id ORDER BY CreatedDate ASC
    ];
    System.assertEquals(2, forms.size(), 'Re-apply must add exactly one Draft');
    System.assertEquals(closed.Id, forms[0].Id);
    System.assertEquals(OAP_Cfrims2DataPullService.stageCompleted(), forms[0].Stage,
      'Closed form must not be reopened');
    System.assertEquals('INF, ARTY', forms[0].OAP_Occupation_Display__c,
      'Dashboard data must land on the submitted form');
    System.assertEquals('Draft', forms[1].Stage);
    System.assertEquals(false, forms[1].CFRIMS_Synced__c);
    System.assertEquals(null, forms[1].OAP_Occupation_Display__c,
      'The reapply Draft must not receive CFRIMS dashboard data');
  }

  // ── CFRIMS bin → ApplicationStatus / Stage ───────────────────────────

  @isTest
  static void stageForBin_mapsKnownBinsAndRejectsUnknown() {
    Set<String> activeStages = new Set<String>();
    for (Schema.PicklistEntry e : ApplicationForm.Stage.getDescribe().getPicklistValues()) {
      if (e.isActive()) activeStages.add(e.getValue());
    }
    String screening = OAP_Cfrims2DataPullService.stageForBin('Initial Processing');
    if (activeStages.contains('Screening')) {
      System.assertEquals('Screening', screening);
      System.assertEquals('Screening',
        OAP_Cfrims2DataPullService.stageForBin('  initial processing '),
        'Bin matching must be case/whitespace-insensitive');
    } else {
      System.assertEquals(null, screening, 'Inactive target must resolve to null');
    }
    System.assertEquals(null, OAP_Cfrims2DataPullService.stageForBin('No Such Bin'));
    System.assertEquals(null, OAP_Cfrims2DataPullService.stageForBin(''));
    System.assertEquals(null, OAP_Cfrims2DataPullService.stageForBin(null));
  }

  @isTest
  static void applyBinTransformation_skipsDraftAndUnknownBin() {
    ApplicationForm draft = new ApplicationForm(Stage = 'Draft', ApplicationStatus = 'Draft');
    OAP_Cfrims2DataPullService.applyBinTransformation(draft, 'Initial Processing');
    System.assertEquals('Draft', draft.Stage, 'Draft forms must never be moved by a bin');

    ApplicationForm submitted = new ApplicationForm(Stage = 'Submitted', ApplicationStatus = 'Submitted');
    OAP_Cfrims2DataPullService.applyBinTransformation(submitted, 'No Such Bin');
    System.assertEquals('Submitted', submitted.Stage);
    System.assertEquals('Submitted', submitted.ApplicationStatus);

    OAP_Cfrims2DataPullService.applyBinTransformation(submitted, null);
    OAP_Cfrims2DataPullService.applyBinTransformation(null, 'Initial Processing');
    System.assertEquals('Submitted', submitted.Stage);

    String expected = OAP_Cfrims2DataPullService.stageForBin('Enrolled');
    OAP_Cfrims2DataPullService.applyBinTransformation(submitted, 'Enrolled');
    System.assertEquals(expected == null ? 'Submitted' : expected, submitted.Stage);
  }

  @isTest
  static void extractBinName_readsRootApplicationsAndBadJson() {
    System.assertEquals('Initial Processing',
      OAP_Cfrims2DataPullService.extractBinName('{"bin_name":"Initial Processing"}'));
    System.assertEquals('Selected',
      OAP_Cfrims2DataPullService.extractBinName(
        '{"applications":[{"bin":" Selected "}]}'));
    System.assertEquals(null,
      OAP_Cfrims2DataPullService.extractBinName('{"applicant_status":"10"}'),
      'No bin key and unmapped file status must yield null');
    System.assertEquals(null, OAP_Cfrims2DataPullService.extractBinName('{bad json'));
    System.assertEquals(null, OAP_Cfrims2DataPullService.extractBinName(null));
  }

  private static Map<String, String> baseHandshake(String email) {
    return new Map<String, String>{
      'accessToken' => OAP_CfrimsTestSupport.futureJwt(),
      'user_key' => 'USERKEY-DATA',
      'session_key' => 'SESSIONKEY-DATA',
      'userIdentifier' => 'UID-DATA',
      'clientSessionId' => 'CSID-DATA',
      'rawBody' => '{"applicant_data":{}}'
    };
  }

  private static String richDashboardBody(String email) {
    return JSON.serialize(
      new Map<String, Object>{
        'personal_info' => new Map<String, Object>{
          'email' => email,
          'pers_Surname' => 'DashboardSurname',
          'alpha_nb' => 'A-DATA-1',
          'service_nb' => 'SVC-DASH'
        },
        'applications' => new List<Object>{
          new Map<String, Object>{
            'application_completed' => 0,
            'submission_date' => '2026-08-01'
          }
        },
        'applicant_status' => '10',
        'applicant_file_status' => '6',
        'applicant_appointments' => null,
        'applicant_tasks' => new List<Object>(),
        'det_contact' => new Map<String, Object>(),
        'occ_display_mos' => 'INF, ARTY',
        'occ_display_component' => 'REG F'
      }
    );
  }

  private static String richHandshakeBody() {
    return JSON.serialize(
      new Map<String, Object>{
        'applicant_data' => new Map<String, Object>{
          'personal_info' => new Map<String, Object>{
            'pers_GivenName' => 'Pat',
            'pers_Surname' => 'Applicant',
            'pers_Preferredname' => 'P',
            'pers_Twins' => 'yes',
            'pers_DateOfBirth' => '2000-01-02',
            'pers_DateOfBirthCity' => 'Toronto',
            'pers_DateOfBirthCountry' => 'CAN',
            'pers_Sex' => 'M',
            'pers_Gender' => 'MAN',
            'language_correpondence' => 'E',
            'language_exam' => 'F',
            'language_interview' => 'E',
            'education_level' => 'bachelor'
          },
          'previous_service' => new Map<String, Object>{
            'prev_servicenumber' => 'PSN-1',
            'prev_trade' => 'yes',
            'prev_service' => 'no',
            'reapplyingForATrade' => true
          },
          'phone' => new Map<String, Object>{
            'primary_phone' => '6135551111',
            'secondary_phone' => '6135552222',
            'primary_phone_text' => '1',
            'secondary_phone_text' => '0'
          },
          'address' => new Map<String, Object>{
            'street_number' => '10',
            'street_name' => 'Base Rd',
            'unit' => '2',
            'city' => 'Kingston',
            'province_code' => 'ON',
            'postal_code' => 'K1A0B1',
            'country_code' => 'CAN',
            'mailing_same_as_home' => false
          },
          'mailing_address' => new Map<String, Object>{
            'street_number' => '20',
            'street_name' => 'Mail Rd',
            'city' => 'Ottawa',
            'province_code' => 'QC',
            'postal_code' => 'H1H1H1',
            'country_code' => 'CAN'
          },
          'declaration' => new Map<String, Object>{
            'ee_selfDeclaration' => true,
            'ee_indigenous' => false,
            'ee_nonindigenous' => true
          },
          'citizenship' => new Map<String, Object>{
            'citizenship_foreign' => true,
            'permanent_resident_date' => '2020-03-04T00:00:00Z'
          },
          'biography' => new Map<String, Object>{
            'criminalConviction' => false,
            'foreignMilitaryService' => true,
            'bornOutside' => false,
            'assetOutsideOfCanada' => true,
            'lifeOutsideOfCanada' => false,
            'immediateRelativeOutcan' => true
          },
          'entry_plan' => new Map<String, Object>{
            'aboriginal_summer_program' => true
          },
          'submit_signature' => 'SIGNED',
          'submit_consent_date' => '2026-08-01T12:00:00Z'
        }
      }
    );
  }
}
