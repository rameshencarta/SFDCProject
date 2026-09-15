import { LightningElement, track } from 'lwc';
import title from '@salesforce/label/c.OAP_Challenge_BirthDetails_Title';
import lastNameBirthCert from '@salesforce/label/c.OAP_Challenge_LastNameBirthCert';
import lastNameRequired from '@salesforce/label/c.OAP_Challenge_LastName_Required';
import dateOfBirth from '@salesforce/label/c.OAP_Challenge_DateOfBirth';
import dateOfBirthRequired from '@salesforce/label/c.OAP_Challenge_DateOfBirth_Required';
import cityOfBirthLabel from '@salesforce/label/c.OAP_Challenge_CityOfBirth';
import cityOfBirthRequired from '@salesforce/label/c.OAP_Challenge_CityOfBirth_Required';
import verify from '@salesforce/label/c.OAP_Challenge_Verify';
import chooseAnotherMethod from '@salesforce/label/c.OAP_Challenge_ChooseAnotherMethod';

export default class Option4BirthDetails extends LightningElement {
    labels = {
        title, lastNameBirthCert, lastNameRequired, dateOfBirth, dateOfBirthRequired,
        cityOfBirth: cityOfBirthLabel, cityOfBirthRequired, verify, chooseAnotherMethod
    };

    @track lastName = '';
    @track dob = '';
    @track cityOfBirth = '';

    get today() {
        return new Date().toISOString().split('T')[0];
    }

    handleLastNameChange(event) { this.lastName = event.target.value; }
    handleDobChange(event)      { this.dob = event.target.value; }
    handleCityChange(event)     { this.cityOfBirth = event.target.value; }

    get isDobValid() {
        return !!this.dob && this.dob <= this.today;
    }

    get isInvalid() {
        return !this.lastName.trim() || !this.isDobValid || !this.cityOfBirth.trim();
    }

    handleVerify() {
        if (this.isInvalid) return;
        this.dispatchEvent(new CustomEvent('submit', {
            detail: {
                answer: {
                    lastName: this.lastName.trim(),
                    dob: this.dob,
                    cityOfBirth: this.cityOfBirth.trim()
                }
            }
        }));
    }

    handleSwitch() {
        this.dispatchEvent(new CustomEvent('switch'));
    }
}