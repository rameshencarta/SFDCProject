import { LightningElement, api, track } from 'lwc';
import title from '@salesforce/label/c.OAP_Challenge_VerifyIdentity_Title';
import selectMethod from '@salesforce/label/c.OAP_Challenge_SelectMethod';
import recommended from '@salesforce/label/c.OAP_Challenge_Recommended';
import continueLabel from '@salesforce/label/c.OAP_Challenge_Continue';
import otherOptionsLabel from '@salesforce/label/c.OAP_Challenge_OtherOptions';
import hideOtherOptions from '@salesforce/label/c.OAP_Challenge_HideOtherOptions';

export default class ChallengeOptionsList extends LightningElement {
    labels = { title, selectMethod, recommended, continueLabel };

    @api availableOptions = [];
    @api defaultOption;

    @track showMore = false;

    get defaultOptionData() {
        return this.availableOptions.find(o => o.code === this.defaultOption);
    }

    get otherOptions() {
        return this.availableOptions.filter(o => o.code !== this.defaultOption);
    }

    get hasMoreOptions() {
        return this.otherOptions.length > 0;
    }

    get moreOptionsLabel() {
        return this.showMore ? hideOtherOptions : otherOptionsLabel;
    }

    get moreOptionsIcon() {
        return this.showMore ? 'utility:chevronup' : 'utility:chevrondown';
    }

    toggleMore() {
        this.showMore = !this.showMore;
    }

    handleDefault() {
        this.fire(this.defaultOption);
    }

    handleOther(event) {
        const code = event.currentTarget.dataset.code;
        this.fire(code);
    }

    fire(code) {
        this.dispatchEvent(new CustomEvent('optionselected', { detail: { code } }));
    }
}