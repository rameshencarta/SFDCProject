import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPortalEntry from '@salesforce/apex/OAP_PortalEntryController.getPortalEntry';
import getLandingRouteOnly from '@salesforce/apex/OAP_PortalEntryController.getLandingRouteOnly';
import submitAnswer from '@salesforce/apex/OAP_Cfrims2ChallengeController.submitAnswer';
import triggerManualMerge from '@salesforce/apex/OAP_Cfrims2ChallengeController.triggerManualMerge';

const ACCOUNT_FIELDS = ['Account.PersonEmail'];

const VERDICT = {
    OPTION_5_REDIRECT: 'OPTION_5_REDIRECT',
    OPTION_5_PENDING:  'OPTION_5_PENDING',
    SHOW_OPTIONS:      'SHOW_OPTIONS'
};

const DEFAULT_ROUTE = '/dashboard';

export default class ChallengeRouter extends NavigationMixin(LightningElement) {
    @api userEmail;
    @api recordId;

    @track ctx;
    @track currentOption;
    @track isLoading = true;
    @track successMessage;
    @track showError = false;
    @track attemptsRemaining;
    @track fatalError;
    @track cfrgReason;
    @track resolvedEmail;

    @wire(getRecord, { recordId: '$recordId', fields: ACCOUNT_FIELDS })
    wiredAccount({ data, error }) {
        if (error) {
            console.warn('[challengeRouter] Account email field load error', JSON.stringify(error));
            this.fatalError = 'Could not read email from this Account. Set userEmail manually in the component property panel.';
            this.isLoading = false;
            return;
        }
        if (data && !this.userEmail) {
            const personEmail = getFieldValue(data, 'Account.PersonEmail');
            if (!personEmail) {
                this.fatalError = 'This Account has no PersonEmail value. Populate one, or set userEmail manually in the component property panel.';
                this.isLoading = false;
                return;
            }
            this.resolvedEmail = personEmail;
            this.bootstrap();
        }
    }

    // ── Experience Builder detection ─────────────────────────────────────────
    // In Experience Builder preview, document.referrer contains
    // 'builder_platform_interaction'. Skip the Apex callout in preview mode
    // to avoid "Apex request id is invalid" when dragging the component.
    // Has NO effect on real portal users (referrer is empty or a portal URL).
    _isBuilderPreview() {
        try {
            const ref = document && document.referrer;
            return !!(ref && ref.includes('builder_platform_interaction'));
        } catch (e) {
            return false;
        }
    }

    connectedCallback() {
        if (this._isBuilderPreview()) {
            this.isLoading = false;
            this.fatalError = 'Challenge Router — place on every page an applicant can land on. Activates automatically for portal users at runtime.';
            return;
        }

        if (this.userEmail) {
            this.resolvedEmail = this.userEmail;
            this.bootstrap();
        } else if (this.recordId) {
            // Wire will fire once the Account record is loaded and call bootstrap().
        } else {
            // Typical portal page: no property, no recordId. Apex derives the
            // email from UserInfo and echoes it back in challengeContext.
            this.bootstrap();
        }
    }

    // Single entry point. getPortalEntry answers "must this applicant verify?"
    // and "where do they belong?" in one round trip, so this component never
    // has to derive a route itself.
    //
    // This component is hosted on the applicant-facing pages rather than a
    // dedicated one, so it must NOT navigate on the non-verification verdicts
    // (NEW_APPLICANT / ROUTE_BY_STATUS / COMPLETE_MERGE_AUTO). Those never
    // reach it now: Apex resolves them to a landingRoute instead. Previously
    // NEW_APPLICANT navigated to the site root, which the landing gate then
    // sent straight back to /application — an infinite redirect loop, since
    // "no ApplicationForm" is exactly what produces both that verdict and
    // that route. Routing belongs to getLandingRoute(); this component only
    // decides whether the applicant may proceed.
    async bootstrap() {
        if (this.bootstrapped) return;
        this.bootstrapped = true;
        try {
            const entry = await getPortalEntry({ userEmail: this.resolvedEmail || null });

            if (entry.errorMessage) {
                console.warn('[challengeRouter] portal entry degraded:', entry.errorMessage);
            }

            if (!entry.needsVerification) {
                this._goTo(entry.landingRoute);
                return;
            }

            this.ctx = entry.challengeContext;
            if (this.ctx && this.ctx.resolvedEmail) {
                this.resolvedEmail = this.ctx.resolvedEmail;
            }
            this.handleVerdict(this.ctx && this.ctx.verdict);
        } catch (e) {
            console.error('[challengeRouter] getPortalEntry failed', e);
            this.fatalError = (e && e.body && e.body.message) || 'Unable to verify identity right now.';
        } finally {
            this.isLoading = false;
        }
    }

    handleVerdict(verdict) {
        switch (verdict) {
            case VERDICT.OPTION_5_REDIRECT:
                // No options available — call manualmerge and show Contact CFRG
                triggerManualMerge({ userEmail: this.resolvedEmail })
                    .catch(e => console.warn('[challengeRouter] manualmerge failed:', e));
                this.cfrgReason = 'system_redirect';
                this.currentOption = '5';
                break;
            case VERDICT.OPTION_5_PENDING:
                // No polling — CFRG approval is async, next login re-evaluates
                this.cfrgReason = 'pending_review';
                this.currentOption = '5';
                break;
            case VERDICT.SHOW_OPTIONS:
                break;
            default:
                // A routing verdict reaching here means Apex classified it as
                // needing verification. Render nothing rather than navigate —
                // navigating is what caused the redirect loop.
                console.warn('[challengeRouter] unexpected verdict, rendering nothing:', verdict);
        }
    }

    handleOptionSelected(event) {
        this.currentOption = event.detail.code;
        if (this.currentOption === '5') {
            this.cfrgReason = 'user_chose';
        }
    }

    async handleAnswerSubmit(event) {
        const { answer } = event.detail;
        this.isLoading = true;
        try {
            const result = await submitAnswer({
                optionCode: this.currentOption,
                answer,
                userEmail: this.resolvedEmail
            });
            if (result.status === 'SUCCESS') {
                await this.routeAfterVerification();
            } else if (result.status === 'WRONG_ANSWER') {
                this.attemptsRemaining = result.attemptsRemaining;
                this.showError = true;
            } else {
                this.cfrgReason = 'failed_attempts';
                this.currentOption = '5';
            }
        } catch (e) {
            this.fatalError = (e && e.body && e.body.message) || 'Validation failed.';
        } finally {
            this.isLoading = false;
        }
    }

    handleTryAgain() {
        this.showError = false;
    }

    handleSwitchOption() {
        this.showError = false;
        this.currentOption = null;
    }

    // Verification just passed, so the applicant may move on. The destination
    // comes from the same source as the login landing redirect — deriving it
    // here from application status instead is how the two could disagree.
    async routeAfterVerification() {
        let route = DEFAULT_ROUTE;
        try {
            route = await getLandingRouteOnly();
        } catch (e) {
            console.warn('[challengeRouter] getLandingRouteOnly failed, using default:', e);
        }
        this._goTo(route);
    }

    // Detect Experience Cloud site — LWR uses /s/ in path, Aura uses the site
    // hostname. lightning.force.com must be excluded explicitly: it contains
    // '.force.com' but is the internal admin UI, not a community.
    _inCommunity() {
        const hostname = window.location.hostname;
        return window.location.pathname.includes('/s/')
            || hostname.includes('.site.com')
            || (hostname.includes('.force.com') && !hostname.includes('lightning.force.com'));
    }

    // Navigates to a site-relative route, but only when the applicant is not
    // already there. assign() to the current URL reloads the page, which would
    // re-run bootstrap and assign again — a reload loop on the very pages this
    // component is meant to sit on.
    _goTo(route) {
        if (!route) return;

        if (!this._inCommunity()) {
            this.successMessage = `Identity verified. Would route to ${route}.`;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Identity verified',
                message: this.successMessage,
                variant: 'success',
                mode: 'sticky'
            }));
            return;
        }

        const currentPath = window.location.pathname.replace(/\/+$/, '');
        if (currentPath.endsWith(route)) return;

        const siteBase = window.location.href.split('/').slice(0, 4).join('/');
        window.location.assign(siteBase + route);
    }

    get showOptions()  { return !this.currentOption && this.ctx && this.ctx.verdict === VERDICT.SHOW_OPTIONS; }
    get isOption1()    { return this.currentOption === '1'; }
    get isOption2()    { return this.currentOption === '2'; }
    get isOption3()    { return this.currentOption === '3'; }
    get isOption4()    { return this.currentOption === '4'; }
    get isOption5()    { return this.currentOption === '5'; }
}
