import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import title from '@salesforce/label/c.OAP_Challenge_Opt5_GetHelp';
import intro from '@salesforce/label/c.OAP_Challenge_GetHelp_Intro';
import systemRedirect from '@salesforce/label/c.OAP_Challenge_GetHelp_SystemRedirect';
import pendingReview from '@salesforce/label/c.OAP_Challenge_GetHelp_PendingReview';
import attemptsExhausted from '@salesforce/label/c.OAP_Challenge_GetHelp_AttemptsExhausted';
import phoneNumber from '@salesforce/label/c.OAP_Challenge_PhoneNumber';
import hoursOfOperation from '@salesforce/label/c.OAP_Challenge_HoursOfOperation';
import reference from '@salesforce/label/c.OAP_Challenge_Reference';
import referenceHint from '@salesforce/label/c.OAP_Challenge_GetHelp_ReferenceHint';
import findRecruiter from '@salesforce/label/c.OAP_Challenge_FindRecruiter';

const REASON_COPY = {
    system_redirect: systemRedirect,
    pending_review: pendingReview,
    user_chose: intro,
    attempts_exhausted: attemptsExhausted
};

export default class Option5ContactCfrg extends NavigationMixin(LightningElement) {
    labels = { title, phoneNumber, hoursOfOperation, reference, referenceHint, findRecruiter };

    @api referenceNumber;
    @api reason;

    get reasonMessage() {
        return REASON_COPY[this.reason] || REASON_COPY.user_chose;
    }

    handleFindRecruiter() {
        // Route to the public CFRG locator page on the community
        this[NavigationMixin.Navigate]({
            type: 'comm__namedPage',
            attributes: { name: 'FindRecruiter' }
        });
    }
}
