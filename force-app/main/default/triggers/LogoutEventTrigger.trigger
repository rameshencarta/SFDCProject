/**
 * Subscribes to the LogoutEventStream platform event so the applicant's
 * CFRIMS session is revoked and cleared however they leave the portal --
 * the custom header menu, the standard Experience Cloud profile menu,
 * /secur/logout or a forced session timeout.
 *
 * Requires LogoutEventStream to be enabled in Setup. Note that no event is
 * published when a user closes the browser, nor on an ordinary session
 * timeout unless "Force logout on session timeout" is enabled.
 *
 * Runs asynchronously as Automated Process, so the user is taken from
 * event.UserId -- UserInfo.getUserId() is not the logging-out applicant
 * here.
 */
trigger LogoutEventTrigger on LogoutEventStream (after insert) {
    Set<Id> userIds = new Set<Id>();

    for (LogoutEventStream event : Trigger.new) {
        if (String.isNotBlank(event.UserId)) {
            userIds.add((Id) event.UserId);
        }
    }

    OAP_CFRIMS_LogoutService.handleLogoutEvents(userIds);
}
