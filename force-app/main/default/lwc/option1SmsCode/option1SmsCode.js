import { LightningElement, api, track } from 'lwc';
import syncPhoneForVerification from '@salesforce/apex/OAP_Cfrims2ChallengeController.syncPhoneForVerification';
import requestSmsCode from '@salesforce/apex/OAP_Cfrims2ChallengeController.requestSmsCode';

export default class Option1SmsCode extends LightningElement {
    @api userEmail;
    @api maskedPhone;

    @track code = '';

    async connectedCallback() {
        await this.dispatchCode();
    }

    // syncPhoneForVerification writes the applicant's phone to the running
    // user's MobilePhone in E.164 and MUST complete as its own Aura round-trip
    // before requestSmsCode: System.UserManagement init(Register)Verification-
    // Method is a callout and cannot share a transaction with the MobilePhone
    // DML. Without it the number never reaches Salesforce in a form it can map
    // to a carrier, so SMS dispatch fails with "Failed to get network info".
    async dispatchCode() {
        try {
            await syncPhoneForVerification({ phoneOnFile: null });
            const masked = await requestSmsCode({ userEmail: this.userEmail });
            if (masked) this.maskedPhone = masked;
        } catch (e) {
            // Dispatch failure surfaces from the parent's fatalError; this child stays quiet.
        }
    }

    handleCodeChange(event) {
        this.code = (event.target.value || '').replace(/[^0-9]/g, '').slice(0, 6);
    }

    get isInvalid() {
        return this.code.length !== 6;
    }

    handleVerify() {
        if (this.isInvalid) return;
        this.dispatchEvent(new CustomEvent('submit', {
            detail: { answer: { code: this.code } }
        }));
    }

    async handleResend() {
        await this.dispatchCode();
    }

    handleSwitch() {
        this.dispatchEvent(new CustomEvent('switch'));
    }
}
