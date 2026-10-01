import { LightningElement, api, track } from 'lwc';
import requestSmsCode from '@salesforce/apex/OAP_Cfrims2ChallengeController.requestSmsCode';
import title from '@salesforce/label/c.OAP_Challenge_Sms_Title';
import intro from '@salesforce/label/c.OAP_Challenge_Sms_Intro';
import codeLabel from '@salesforce/label/c.OAP_Challenge_Sms_CodeLabel';
import codePattern from '@salesforce/label/c.OAP_Challenge_Sms_CodePattern';
import verifyCode from '@salesforce/label/c.OAP_Challenge_Sms_VerifyCode';
import resend from '@salesforce/label/c.OAP_Challenge_Sms_Resend';
import sendingLabel from '@salesforce/label/c.OAP_Challenge_Sms_Sending';
import sendFailed from '@salesforce/label/c.OAP_Challenge_Sms_SendFailed';
import chooseAnotherMethod from '@salesforce/label/c.OAP_Challenge_ChooseAnotherMethod';

const PHONE_PLACEHOLDER = '{0}';

export default class Option1SmsCode extends LightningElement {
    labels = { title, codeLabel, codePattern, verifyCode, resend, sending: sendingLabel, chooseAnotherMethod };

    @api userEmail;
    @api maskedPhone;

    @track code = '';
    @track dispatchError = '';
    @track sending = false;

    // Intro copy is "... sent to {0}. ..."; the phone is rendered in its own
    // <strong> so the sentence is split around the placeholder.
    get introBefore() {
        const i = intro.indexOf(PHONE_PLACEHOLDER);
        return i < 0 ? intro : intro.slice(0, i);
    }

    get introAfter() {
        const i = intro.indexOf(PHONE_PLACEHOLDER);
        return i < 0 ? '' : intro.slice(i + PHONE_PLACEHOLDER.length);
    }

    async connectedCallback() {
        await this.dispatchCode();
    }

    // requestSmsCode now generates the code server-side and sends it through
    // the Google CCAI delivery handler, so the previous syncPhoneForVerification
    // round-trip (which existed only to feed the phone to Salesforce Identity
    // Verification) is no longer needed.
    async dispatchCode() {
        this.sending = true;
        this.dispatchError = '';
        try {
            const masked = await requestSmsCode({ userEmail: this.userEmail });
            if (masked) this.maskedPhone = masked;
        } catch (e) {
            // A silent failure here left the applicant staring at a code entry
            // screen with no SMS and no explanation; show the server's
            // user-safe message instead.
            this.dispatchError = this.readError(e);
        } finally {
            this.sending = false;
        }
    }

    readError(error) {
        const body = error && error.body ? error.body : error;
        return (
            (body && (body.message || body.pageErrors?.[0]?.message)) ||
            sendFailed
        );
    }

    handleCodeChange(event) {
        this.code = (event.target.value || '').replace(/[^0-9]/g, '').slice(0, 6);
    }

    get isInvalid() {
        return this.code.length !== 6;
    }

    get canVerify() {
        return !this.isInvalid && !this.sending;
    }

    get verifyDisabled() {
        return !this.canVerify;
    }

    handleVerify() {
        if (!this.canVerify) return;
        this.dispatchEvent(new CustomEvent('submit', {
            detail: { answer: { code: this.code } }
        }));
    }

    async handleResend() {
        this.code = '';
        await this.dispatchCode();
    }

    handleSwitch() {
        this.dispatchEvent(new CustomEvent('switch'));
    }
}
