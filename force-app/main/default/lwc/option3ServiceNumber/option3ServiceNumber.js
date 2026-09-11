import { LightningElement, track } from 'lwc';
import title from '@salesforce/label/c.OAP_Challenge_Opt3_ServiceNumber';
import serviceNumberLabel from '@salesforce/label/c.OAP_Challenge_ServiceNumber';
import serviceNumberRequired from '@salesforce/label/c.OAP_Challenge_ServiceNumber_Required';
import dateOfBirth from '@salesforce/label/c.OAP_Challenge_DateOfBirth';
import dateOfBirthRequired from '@salesforce/label/c.OAP_Challenge_DateOfBirth_Required';
import verify from '@salesforce/label/c.OAP_Challenge_Verify';
import chooseAnotherMethod from '@salesforce/label/c.OAP_Challenge_ChooseAnotherMethod';

export default class Option3ServiceNumber extends LightningElement {
    labels = { title, serviceNumber: serviceNumberLabel, serviceNumberRequired, dateOfBirth, dateOfBirthRequired, verify, chooseAnotherMethod };

    @track serviceNumber = '';
    @track dob = '';

    get today() {
        return new Date().toISOString().split('T')[0];
    }

    handleServiceChange(event) {
        // Strip non-alphanumeric, uppercase, cap at 9
        this.serviceNumber = (event.target.value || '')
            .replace(/[^A-Za-z0-9]/g, '')
            .toUpperCase()
            .slice(0, 9);
    }

    handleDobChange(event) {
        this.dob = event.target.value;
    }

    get isDobValid() {
        return !!this.dob && this.dob <= this.today;
    }

    get isInvalid() {
        return this.serviceNumber.length !== 9 || !this.isDobValid;
    }

    handleVerify() {
        if (this.isInvalid) return;
        this.dispatchEvent(new CustomEvent('submit', {
            detail: {
                answer: {
                    serviceNumber: this.serviceNumber,
                    dob: this.dob
                }
            }
        }));
    }

    handleSwitch() {
        this.dispatchEvent(new CustomEvent('switch'));
    }
}