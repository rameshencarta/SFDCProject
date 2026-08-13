public with sharing class OAP_PortalEntryController {

    public class PortalEntryResult {
        @AuraEnabled public Boolean needsVerification;
        @AuraEnabled public OAP_Cfrims2ChallengeController.ChallengeContext challengeContext;
        @AuraEnabled public String landingRoute; // populated only when needsVerification = false
        @AuraEnabled public String errorMessage;
    }

    // userEmail is a pass-through to startSession, which falls back to
    // UserInfo.getUserEmail() when it is null. Portal users pass null; the
    // admin/internal test path (challengeRouter on an Account record page)
    // passes the Account's PersonEmail, which would otherwise be replaced by
    // the admin's own email and verify the wrong identity.
    @AuraEnabled
    public static PortalEntryResult getPortalEntry(String userEmail) {
        PortalEntryResult result = new PortalEntryResult();
        try {
            OAP_Cfrims2ChallengeController.ChallengeContext ctx =
                OAP_Cfrims2ChallengeController.startSession(userEmail);

            result.needsVerification = isVerificationVerdict(ctx.verdict);

            if (result.needsVerification) {
                result.challengeContext = ctx;
            } else {
                result.landingRoute = OAP_ApplicantContextController.getLandingRoute();
            }
        } catch (Exception e) {
            // Fail OPEN — a broken CFRIMS session check must never trap a
            // real applicant outside the portal. Log loudly, let them
            // through to normal Stage-based routing.
            System.debug(LoggingLevel.ERROR,
                'OAP_PortalEntryController.getPortalEntry failed, proceeding '
                + 'without verification: ' + e.getMessage());
            result.needsVerification = false;
            // Generic — the raw exception can carry endpoint/internal detail and
            // this value reaches a portal user. The specifics stay in the log above.
            result.errorMessage = 'Identity verification was skipped.';
            try {
                result.landingRoute = OAP_ApplicantContextController.getLandingRoute();
            } catch (Exception e2) {
                result.landingRoute = '/dashboard'; // last-resort default
            }
        }
        return result;
    }

    // Called by the challenge router LWC once verification succeeds — does
    // NOT re-check verification (already resolved), just gets where to go.
    @AuraEnabled
    public static String getLandingRouteOnly() {
        try {
            return OAP_ApplicantContextController.getLandingRoute();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'OAP_PortalEntryController.getLandingRouteOnly failed: ' + e.getMessage());
            return '/dashboard';
        }
    }

    @TestVisible
    private static Boolean isVerificationVerdict(String verdict) {
        if (String.isBlank(verdict)) return false;
        Set<String> verificationVerdicts = new Set<String>{
            'SHOW_OPTIONS', 'OPTION_5_PENDING', 'OPTION_5_REDIRECT'
        };
        return verificationVerdicts.contains(verdict);
    }
}