/**
 * @description Challenge controller for the challengeRouter LWC.
 *              Handles handshake, merge state check, challenge submission and completeMerge.
 * @author Ramesh / DND
 * @date 2026-05-26
 * @group Integration Framework
 *
 * Version                     Date                          Author
 * v1                          26-May-2026                   Ramesh - Initial version
 * v2                          17-Jun-2026                   Ramesh - Renamed to OAP_Cfrims2ChallengeController
 *                                                                    Updated all references to OAP_ prefix
 * v3                          21-Jul-2026                   Ramesh - Fixed stored-token session synthesis:
 *                                                                    the reuse path was putting clientSessionId
 *                                                                    (SF_SESS_...) into 'session_key' and omitting
 *                                                                    'clientSessionId' entirely — every gatewayBase
 *                                                                    consumer of the cached map (checkMergeState,
 *                                                                    completeMerge, DataPullService) then failed
 *                                                                    with ORA-20004 "Invalid Keys or Session
 *                                                                    Mismatch". session_key/user_key/identifiers
 *                                                                    are now decoded from the stored JWT's claims.
 *                                                                    Added token expiry check (30-min exp) before
 *                                                                    reuse — expired tokens fall through to a
 *                                                                    fresh handshake instead of a guaranteed 401.
 * v4                          22-Jul-2026                   Ramesh - UK_EMAIL recovery no longer routes to
 *                                                                    NEW_APPLICANT (contradiction: ORA-00001
 *                                                                    proves the email exists in CFRIMS). CFRIMS
 *                                                                    observed returning an EMPTY default payload
 *                                                                    in this error — existing applicants were
 *                                                                    being routed to Home as new users. Empty
 *                                                                    payload now routes to CFRG review
 *                                                                    (identifier-mismatch suspected); real
 *                                                                    payloads route by status.
 *                                                                    ALSO v4: returning applicants were routed
 *                                                                    to Home on every stored-token login —
 *                                                                    applyAccountStateOverrides only recognised
 *                                                                    Alpha Number / Applicant Status (populated
 *                                                                    late, by the dashboard pull) and ignored
 *                                                                    CFRIMS_Sync_Status__pc = 'Success' (set at
 *                                                                    submit time). Now checks Sync Status, the
 *                                                                    ApplicationForm stage, and reads via a
 *                                                                    without-sharing helper (portal users lacked
 *                                                                    reliable read access to these fields).
 */
public with sharing class OAP_Cfrims2ChallengeController {

    @AuraEnabled
    public static ChallengeContext startSession(String userEmail) {
        // Allow a blank/null userEmail — fall back to the logged-in user's email.
        // {!CurrentUser.Email} is unreliable as an @api prop in Aura Experience
        // Cloud sites and may arrive as null even for authenticated users.
        // UserInfo.getUserEmail() is always authoritative on the server side.
        if (String.isBlank(userEmail)) {
            userEmail = UserInfo.getUserEmail();
        }
        if (String.isBlank(userEmail)) {
            throw new AuraHandledException('Email is required.');
        }
        try {
            // Fetch stored identifiers — reusing both prevents UK_USER_KEY constraint
            // violations on repeat logins. Cfrims2HandshakeIdStore uses clientSessionId
            // as its cache key: regenerating it on every call causes a cache miss which
            // forces CFRIMS to INSERT a new user_key, hitting the unique constraint.
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
                // No stored identifier — generate a fresh GUID and proceed.
                //
                // Two possible outcomes after the callout:
                //   • Brand-new user (no CFRIMS record yet): CFRIMS returns 404
                //     → synthesiseNoMergePayload → NEW_APPLICANT. Safe to call.
                //   • Existing CFRIMS user whose identifier hasn't synced back:
                //     CFRIMS returns UK_EMAIL / UK_SF_ID constraint error but still
                //     embeds the full CasePayload in the body. The catch block
                //     below parses that payload and routes correctly.
                //
                // A pre-emptive "sync in progress" block was tried here but it
                // over-blocked brand-new users who should go straight to the
                // CAF application form as NEW_APPLICANT.
                userIdentifier = 'SF-GUID-' + String.valueOf(Math.abs(Crypto.getRandomLong()));
            }
            clientSessionId = (!accts.isEmpty()
                    && String.isNotBlank(accts[0].CFRIMS_Client_Session_Id__pc))
                ? accts[0].CFRIMS_Client_Session_Id__pc
                : 'SF_SESS_' + String.valueOf(Crypto.getRandomLong());
            // ── Skip handshake if valid session already stored (v3) ──────────────
            // Abakar confirmed: each performHandshake creates a NEW session record
            // in CFRIMS's event_table. Multiple logins = multiple session rows.
            // If the Account already has a stored accessToken and user_key from
            // a previous login, reuse them — do NOT call handshake again.
            //
            // v3 FIX: the synthesised map previously set
            //     'session_key' => clientSessionId        (an SF_SESS_... value)
            // and omitted 'clientSessionId' entirely. The REAL session_key only
            // exists inside the JWT claims. Every gatewayBase built from the old
            // map was rejected by CFRIMS with ORA-20004 "Invalid Keys or Session
            // Mismatch" (TRG_VALIDATE_API_EVENT). All session values are now
            // decoded from the token itself — the same values the original
            // handshake response returned. Expired tokens (30-min exp) fall
            // through to a fresh handshake.
            String storedToken   = !accts.isEmpty() ? accts[0].CFRIMS_Access_Token__pc   : null;
            String storedUserKey = !accts.isEmpty() ? accts[0].user_key__pc              : null;
            Map<String, String> handshake = null;

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
                // claims missing session_key/user_key → handshake below
            }

            if (handshake == null) {
                System.debug('[startSession] No valid stored token — calling performHandshake');
                handshake = OAP_CFRIMS_ApiClient.performHandshake(
                    userEmail, userIdentifier, clientSessionId);
            }

            // Keep locals aligned with whichever session is live — these are
            // persisted to the Account below and must match the token's claims.
            if (String.isNotBlank(handshake.get('userIdentifier'))) {
                userIdentifier = handshake.get('userIdentifier');
            }
            if (String.isNotBlank(handshake.get('clientSessionId'))) {
                clientSessionId = handshake.get('clientSessionId');
            }
            // ─────────────────────────────────────────────────────────────────
            CasePayload payload = extractMergePayloadFromHandshake(handshake.get('rawBody'));
            // True only when CFRIMS returns 404 / empty body — user has no CFRIMS record yet.
            Boolean isSynthesised = false;

            if (payload == null) {
                // If we skipped handshake (stored token path), rawBody is null.
                // Determine payload from stored Account fields instead of calling CFRIMS.
                if (String.isNotBlank(handshake.get('accessToken'))
                    && handshake.get('rawBody') == null) {
                    // Use synthesised payload — applicant has a stored session
                    // so they have been through handshake before (no merge needed)
                    payload = synthesiseNoMergePayload();
                    isSynthesised = true;
                    System.debug('[startSession] Using synthesised payload (stored token path)');
                } else {
                    OAP_CFRIMS_ApiClient.MergeStateResponse mergeResp =
                        OAP_CFRIMS_ApiClient.checkMergeState(handshake, userEmail);

                    if (mergeResp.res.getStatusCode() == 404
                        || (mergeResp.res.getStatusCode() == 200 && String.isBlank(mergeResp.decryptedBody))) {
                        payload = synthesiseNoMergePayload();
                        isSynthesised = true;
                    } else if (mergeResp.res.getStatusCode() != 200 || String.isBlank(mergeResp.decryptedBody)) {
                        throw new AuraHandledException('Identity service returned an unexpected response.');
                    } else {
                        payload = (CasePayload) JSON.deserialize(mergeResp.decryptedBody, CasePayload.class);
                    }
                }
            }

            applyAccountStateOverrides(userEmail, payload);

            // Inline verdict logic (replaces ChallengeRouter.decide())
            String verdict;
            if (payload.require_merge != 1) {
                // Brand-new user: CFRIMS had no record (synthesised payload) and the applicant
                // has not yet completed their application — send them straight to the CAF form.
                verdict = (isSynthesised && payload.application_completed == 0)
                    ? 'NEW_APPLICANT'
                    : 'ROUTE_BY_STATUS';
            } else if (payload.redirect_to_cfrg == true) {
                verdict = 'OPTION_5_REDIRECT';
            } else if (payload.manual_merge_required == 1) {
                verdict = payload.merge_approved == 1 ? 'COMPLETE_MERGE_AUTO' : 'OPTION_5_PENDING';
            } else {
                verdict = 'SHOW_OPTIONS';
            }

            // ── ALL callouts must complete before ANY DML ────────────────────────────
            // OAP_Cfrims2SessionCache and OAP_ChallengeAttemptTracker both write to
            // SObjects (DML). completeMerge is a callout. Salesforce blocks callouts
            // after DML in the same transaction, so completeMerge must fire first.
            if (verdict == 'COMPLETE_MERGE_AUTO') {
                try {
                    OAP_CFRIMS_ApiClient.completeMerge(handshake, userEmail);
                } catch (Exception mergeEx) {
                    // Log but do not rethrow — application_completed=1 is already in
                    // the payload so routing to the dashboard still works correctly.
                    System.debug('[startSession] completeMerge non-fatal error: ' + mergeEx.getMessage());
                }
            }
            // ─────────────────────────────────────────────────────────────────────────

            Id userId = UserInfo.getUserId();
            OAP_Cfrims2SessionCache.putHandshake(userId, handshake);
            OAP_Cfrims2SessionCache.putCasePayload(userId, payload);
            OAP_ChallengeAttemptTracker.reset(userId);

            // Save userIdentifier last — after all callouts and cache writes
            try {
                List<Account> accsToUpdate = [
                    SELECT Id FROM Account
                    WHERE PersonEmail = :userEmail
                    ORDER BY LastModifiedDate DESC
                    LIMIT 1
                ];
                if (!accsToUpdate.isEmpty()) {
                    Account acctToSave = accsToUpdate[0];
                    // Store ALL session data from the login handshake.
                    // Abakar confirmed: generate session keys ONCE at login,
                    // reuse them for submit — never call handshake again.
                    acctToSave.CFRIMS_User_Identifier__pc  = userIdentifier;
                    acctToSave.CFRIMS_Client_Session_Id__pc = clientSessionId;
                    acctToSave.user_key__pc                 = handshake.get('user_key');
                    acctToSave.CFRIMS_Access_Token__pc      = handshake.get('accessToken');
                    update acctToSave;

                    // COMPLETE_MERGE_AUTO: inbound applicant whose CFRIMS record
                    // is already approved. Trigger dashboard fetch to populate Salesforce.
                    // Do NOT create an ApplicationForm here — that caused duplicates when
                    // the Account in startSession differed from the one in DataPullService.
                    // OAP_Cfrims2DashboardFetcher.applyDashboardToSalesforce already has
                    // a null-formId guard that looks up the most recent form by AccountId.
                    if (verdict == 'COMPLETE_MERGE_AUTO') {
                        List<ApplicationForm> existingForms = [
                            SELECT Id FROM ApplicationForm
                            WHERE AccountId = :acctToSave.Id
                            ORDER BY CreatedDate DESC LIMIT 1
                        ];
                        // Pass existing formId if found, null otherwise.
                        // DashboardFetcher handles null by querying the form itself.
                        Id formId = existingForms.isEmpty() ? null : existingForms[0].Id;
                        OAP_Cfrims2DashboardFetcher.fetchAsync(acctToSave.Id, formId, userEmail);
                    }
                }
            } catch (Exception saveEx) {
                System.debug('Could not save userIdentifier / trigger dashboard fetch: ' + saveEx.getMessage());
            }

            ChallengeContext result = buildContext(verdict, payload);
            result.resolvedEmail = userEmail;
            // Store accessToken so Account.CFRIMS_Access_Token__pc is populated
            // and sendApplicationToCFRIMS can use it without a second handshake
            result.accessToken   = handshake.get('accessToken');
            // Resolve ApplicationForm ID so the LWC can navigate directly
            // to the record page (Option B) instead of a generic named page.
            // Only needed when the application is not yet completed.
            if (!result.applicationCompleted) {
                List<ApplicationForm> forms = [
                    SELECT Id FROM ApplicationForm
                    WHERE Account.PersonEmail = :userEmail
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                if (!forms.isEmpty()) {
                    result.applicationFormId = forms[0].Id;
                }
            }
            return result;

        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            // ── UK_EMAIL recovery ────────────────────────────────────────────
            // When a fresh GUID is sent for an email that already exists in
            // CFRIMS, the handshake returns HTTP 401 with Oracle error:
            //   ORA-00001: unique constraint (CFRG.UK_EMAIL) violated
            // CFRIMS still embeds the user's full CasePayload in the error
            // body (require_merge, application_completed, options, etc.), so
            // we can parse it and route correctly rather than showing a
            // generic error.  This covers the case where the user exists in
            // CFRIMS but has no matching Salesforce Account (so no stored
            // user identifier is found and a fresh GUID is generated).
            String rawMsg = e.getMessage();
            // CFRIMS uses two constraint names depending on which duplicate
            // column fires: UK_EMAIL when the email is the duplicate, and
            // UK_SF_ID when the Salesforce session ID is the duplicate
            // (happens when clientSessionId was not persisted on a prior login).
            if (rawMsg != null && (
                rawMsg.contains('UK_EMAIL') ||
                rawMsg.contains('UK_SF_ID') ||
                rawMsg.contains('UK_USER_KEY') ||   // original Oracle constraint — same recovery
                // CFRIMS C# type mismatch error — same recovery handles it
                rawMsg.contains('Cannot get the value of a token type')
            )) {
                try {
                    Integer jsonStart = rawMsg.indexOf('{');
                    if (jsonStart >= 0) {
                        CasePayload recovered = (CasePayload) JSON.deserialize(
                            rawMsg.substring(jsonStart), CasePayload.class);
                        applyAccountStateOverrides(userEmail, recovered);
                        String v;

                        // ── v4 fix (22-Jul-2026) ─────────────────────────────
                        // ORA-00001 on UK_EMAIL PROVES this email already exists
                        // in CFRIMS — so 'NEW_APPLICANT' is a contradiction in
                        // this branch and must never be returned here. The old
                        // logic trusted the embedded flags, but CFRIMS was
                        // observed (22-Jul, PP2-TRG) returning an EMPTY default
                        // payload in this error (all flags 0, no identity data,
                        // blank accessToken) — which looked exactly like a new
                        // applicant and routed EXISTING applicants to Home.
                        Boolean payloadIsEmptyDefaults =
                            (recovered.require_merge == null || recovered.require_merge == 0)
                            && (recovered.application_completed == null || recovered.application_completed == 0)
                            && (recovered.manual_merge_required == null || recovered.manual_merge_required == 0)
                            && (recovered.merge_approved == null || recovered.merge_approved == 0)
                            && recovered.security_question == null;

                        if (payloadIsEmptyDefaults) {
                            // Empty payload + email-exists constraint ⇒ CFRIMS
                            // gave us no usable state. Most likely cause: we
                            // presented a UserIdentifier CFRIMS does not
                            // associate with this email (identifier mismatch —
                            // lost/regenerated on our side, or reused email).
                            // No self-service recovery exists without the
                            // original identifier → route to CFRG review, NOT
                            // Home. Recovery: restore the original identifier
                            // (from CFRIMS API Log History of this email's
                            // first handshake) to CFRIMS_User_Identifier__pc.
                            System.debug(LoggingLevel.ERROR,
                                '[startSession] UK_EMAIL with EMPTY payload for '
                                + userEmail + ' — identifier mismatch suspected; '
                                + 'routing to CFRG review. Restore the original '
                                + 'UserIdentifier from API logs to recover this user.');
                            v = 'OPTION_5_PENDING';
                        } else if (recovered.require_merge != 1) {
                            // Real payload, no merge required: the email exists
                            // in CFRIMS (the constraint fired), so route by
                            // status — never NEW_APPLICANT from this path.
                            v = 'ROUTE_BY_STATUS';
                        } else {
                            // Merge required but we have no valid handshake to
                            // submit answers against.  Route to CFRG review so
                            // the user can be re-evaluated on next login once
                            // their Account is correctly linked in Salesforce.
                            v = 'OPTION_5_PENDING';
                        }
                        Id uid = UserInfo.getUserId();
                        OAP_Cfrims2SessionCache.putCasePayload(uid, recovered);
                        OAP_ChallengeAttemptTracker.reset(uid);
                        ChallengeContext recovCtx = buildContext(v, recovered);
                        recovCtx.resolvedEmail = userEmail;
                        if (!recovCtx.applicationCompleted) {
                            List<ApplicationForm> recovForms = [
                                SELECT Id FROM ApplicationForm
                                WHERE Account.PersonEmail = :userEmail
                                ORDER BY CreatedDate DESC LIMIT 1
                            ];
                            if (!recovForms.isEmpty()) {
                                recovCtx.applicationFormId = recovForms[0].Id;
                            }
                        }
                        return recovCtx;
                    }
                } catch (Exception parseEx) {
                    System.debug('[startSession] UK_EMAIL recovery parse failed: '
                        + parseEx.getMessage());
                }
            }
            // Unrecoverable handshake failure — not one of the known recoverable
            // constraint violations above (e.g. a backend Oracle error such as
            // ORA-22922 "nonexistent LOB value" / ORA-06512 raised inside the
            // CFRIMS gateway). Previously this fell straight through to the
            // generic message with no server-side trace, so the real cause was
            // invisible in the logs. Log the full CFRIMS error (matching the v4
            // catch-all pattern) while keeping the user message safe.
            System.debug(LoggingLevel.ERROR, '[startSession] Unrecovered CFRIMS '
                + 'handshake failure for ' + userEmail + ': ' + rawMsg
                + '\n' + e.getStackTraceString());
            throw new AuraHandledException('Identity service unavailable. Please try again shortly.');
        } catch (AuraHandledException ahe) {
            throw ahe; // already user-safe — pass through unchanged
        } catch (Exception ex) {
            // ── v4: catch-all ────────────────────────────────────────────────
            // Previously only CFRIMS_Exception was handled; any other type
            // (DmlException from SessionCache/AttemptTracker, QueryException,
            // NPE) escaped unwrapped and the portal showed the framework's
            // opaque "Failed to get error from response". Surface the real
            // type/message so failures are diagnosable from the UI and logs.
            System.debug(LoggingLevel.ERROR, '[startSession] Unhandled '
                + ex.getTypeName() + ': ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());
            throw new AuraHandledException('Sign-in check failed ('
                + ex.getTypeName() + '): ' + ex.getMessage());
        }
    }

    // ── JWT helpers (v3) ─────────────────────────────────────────────────────
    // Decode the payload segment of a JWT (base64url) into its claims map.
    // CFRIMS token claims include: nameid (= user_key), email, session_key,
    // UserIdentifier, ClientSessionID, nbf, exp, iat (verified 21-Jul PP2-TRG).
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

    // CFRIMS tokens live 30 minutes (exp − iat = 1800s). 60s safety buffer.
    // Unparseable → treated as expired so the caller handshakes fresh.
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
    // ─────────────────────────────────────────────────────────────────────────

    // ── v5: portal session-extension endpoints (spec §2.2 /Auth/keepalive) ──
    // For the session-timer UX: the portal warns ~5 min before token expiry
    // ("Do you want to continue?"); Continue → extendSession().

    /** Seconds until the logged-in user's stored CFRIMS token expires.
     *  0 = no usable session (expired/absent) — the timer LWC should treat
     *  that as "next CFRIMS action will re-establish or fail visibly". */
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

    /** Renews the CFRIMS session via /Auth/keepalive and persists the fresh
     *  token. Returns the new remaining seconds. Must be called while the
     *  current token is still valid (keepalive "requires active" session). */
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
    private static void applyAccountStateOverrides(String userEmail, CasePayload payload) {
        if (payload == null || String.isBlank(userEmail)) return;
        if (payload.application_completed == 1) return;
        try {
            // v4: read via without-sharing helper — this runs as the PORTAL
            // user, and sharing/FLS gaps on integration fields were silently
            // returning blanks, so the override never fired and returning
            // applicants were routed to Home as NEW_APPLICANT.
            AccountStateReader reader = new AccountStateReader();
            List<Account> matches = reader.byEmail(userEmail);
            if (matches.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    '[applyAccountStateOverrides] no Account visible for ' + userEmail);
                return;
            }
            Account a = matches[0];
            // v4: CFRIMS_Sync_Status__pc = 'Success' is the AUTHORITATIVE
            // submitted signal — written by the submit handler at the moment
            // of success. Alpha Number / Applicant Status only arrive later
            // via the dashboard pull, so applicants whose pull hadn't run yet
            // (or partially failed) were misclassified as new on every login.
            // v4.1: the Sync Status picklist has a wider lifecycle than the
            // three values written by the reviewed Apex. All of these mean
            // "an application was submitted — NOT a new applicant":
            //   Success | Submitted | Submitted – Pending Dashboard
            //   Pending CFRIMS Sync | Manual Review
            // Deliberately excluded: 'In Progress' (pre-submit), 'Failed'
            // (submit never landed), 'Already Registered' (burned email —
            // contact-CFRG is the correct destination for them).
            Set<String> submittedStatuses = new Set<String>{
                'Success', 'Submitted', 'Submitted – Pending Dashboard',
                'Submitted - Pending Dashboard', // both dash variants, defensively
                'Pending CFRIMS Sync', 'Manual Review'
            };
            Boolean salesforceSaysSubmitted =
                submittedStatuses.contains(a.CFRIMS_Sync_Status__pc)
                || String.isNotBlank(a.CFRIMS_Alpha_Number__pc)
                || String.isNotBlank(a.CFRIMS_Applicant_Status__pc);

            // Belt-and-braces: a submitted/completed ApplicationForm also
            // proves this is not a new applicant, even if account-level
            // integration fields were cleared.
            if (!salesforceSaysSubmitted) {
                salesforceSaysSubmitted = reader.hasSubmittedForm(a.Id);
            }

            System.debug('[applyAccountStateOverrides] ' + userEmail
                + ' syncStatus=' + a.CFRIMS_Sync_Status__pc
                + ' alpha=' + a.CFRIMS_Alpha_Number__pc
                + ' applicantStatus=' + a.CFRIMS_Applicant_Status__pc
                + ' → submitted=' + salesforceSaysSubmitted);

            if (salesforceSaysSubmitted) payload.application_completed = 1;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[applyAccountStateOverrides] failed (non-fatal): ' + e.getMessage());
        }
    }

    // v4: sharing-safe reader for the user's own integration state.
    // startSession executes as the portal user; org sharing rules do not
    // reliably grant them read access to these integration fields on their
    // own Person Account. Scope is strictly limited to the two lookups below.
    // (Instance methods — Apex forbids static members on inner classes.)
    private without sharing class AccountStateReader {
        private List<Account> byEmail(String email) {
            return [
                SELECT Id, CFRIMS_Alpha_Number__pc, CFRIMS_Applicant_Status__pc,
                       CFRIMS_Sync_Status__pc
                FROM Account WHERE PersonEmail = :email LIMIT 1
            ];
        }
        // v5: session lookup for the keepalive endpoints — reads the stored
        // token without requiring portal FLS on the token field.
        private Account sessionByEmail(String email) {
            List<Account> matches = [
                SELECT Id, CFRIMS_Access_Token__pc
                FROM Account WHERE PersonEmail = :email LIMIT 1
            ];
            return matches.isEmpty() ? null : matches[0];
        }

        private Boolean hasSubmittedForm(Id accountId) {
            // v4.1: SubmissionDate removed from the criteria — this org
            // populates it at form CREATION (Draft), not at submit, so it
            // was classifying every draft-holder as submitted and routing
            // unsubmitted users to the dashboard. Stage and the sync flag
            // are the only trustworthy submitted signals on the form.
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
        if (String.isBlank(optionCode) || String.isBlank(userEmail)) {
            throw new AuraHandledException('Missing required input.');
        }
        try {
            Boolean passed = OAP_Cfrims2ChallengeService.validate(optionCode, answer, userEmail);

            if (passed) {
                // CFRIMS confirmed: there is no /Applicants/challenge endpoint.
                // All challenge verification is done locally using data from the handshake
                // response — OAP_Cfrims2ChallengeService.validate() above is the full gate.
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

        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            throw new AuraHandledException('Validation failed: ' + e.getMessage());
        }
    }

    // Called when applicant fails all challenges or no options available
    // Calls /Applicants/manualmerge then routes to Contact CFRG page
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
                : 'SF-GUID-' + String.valueOf(Math.abs(Crypto.getRandomLong()));

            // Call manualmerge endpoint — fires and forgets
            // CFRG team handles approval asynchronously
            OAP_CalloutService.invoke(JSON.serialize(new Map<String, String>{
                'email'          => userEmail,
                'service'        => 'manualMerge',
                'userIdentifier' => userIdentifier
            }));
            System.debug('OAP_Cfrims2ChallengeController: manualmerge called for ' + userEmail);
        } catch (Exception e) {
            // Non-fatal — user is already routed to Contact CFRG page
            System.debug('OAP_Cfrims2ChallengeController: manualmerge failed (non-fatal): '
                + e.getMessage());
        }
    }

    // MUST be called and awaited by the LWC as a SEPARATE Aura round-trip
    // BEFORE requestSmsCode. System.UserManagement.init(Register)Verification-
    // Method is treated as a callout by the platform, and Apex cannot commit
    // DML mid-transaction, so the MobilePhone update below and that call can
    // never share one Aura invocation ("A callout was unsuccessful because of
    // pending uncommitted work..."). The number the SMS is actually sent to is
    // the running user's MobilePhone — Salesforce needs it in strict E.164 to
    // resolve the carrier, otherwise init...VerificationMethod returns
    // "Failed to get network info". The phone is resolved server-side (the LWC
    // only has a masked number) from the same source requestSmsCode uses.
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

    // Salesforce validates the stored MobilePhone against its own formatting
    // rules when registering it for SMS; a mismatch surfaces as "We cannot
    // verify this phone number. Check its format and try again." Use the
    // platform's own System.UserManagement.formatPhoneNumber (the API Salesforce
    // documents for exactly this purpose) to produce the expected format, and
    // fall back to the local E.164 conversion only if it returns nothing.
    private static String formatForVerification(String phone) {
        try {
            String formatted = System.UserManagement.formatPhoneNumber('1', phone);
            if (String.isNotBlank(formatted)) return formatted;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[formatForVerification] formatPhoneNumber failed, using toE164: '
                + e.getMessage());
        }
        return OAP_Cfrims2ChallengeService.toE164(phone);
    }

    @AuraEnabled
    public static String requestSmsCode(String userEmail) {
        try {
            return OAP_Cfrims2ChallengeService.requestSmsCode(userEmail, resolveApplicantPhone());
        } catch (OAP_CFRIMS_ApiClient.CFRIMS_Exception e) {
            throw new AuraHandledException('Could not send code. Please try a different option.');
        }
    }

    // Resolves the applicant's phone. OAP_Cfrims2SessionCache is backed by
    // Cache.Session, whose writes silently fall back to a transaction-local map
    // when the org has no session cache capacity — so by a later Aura round-trip
    // the cached payload (and its phone) can be gone. Fall back to the running
    // user's MobilePhone so a cache miss does not surface a false "no phone on
    // file".
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

    // ── DTOs ─────────────────────────────────────────────────────────────────

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