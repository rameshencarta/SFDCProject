import { LightningElement, api, track } from 'lwc';
import title from '@salesforce/label/c.OAP_Challenge_SecurityQuestions_Title';
import securityQuestions from '@salesforce/label/c.OAP_Challenge_SecurityQuestions';
import answer from '@salesforce/label/c.OAP_Challenge_Answer';
import verify from '@salesforce/label/c.OAP_Challenge_Verify';
import useDifferentQuestion from '@salesforce/label/c.OAP_Challenge_UseDifferentQuestion';
import chooseAnotherMethod from '@salesforce/label/c.OAP_Challenge_ChooseAnotherMethod';

export default class Option2SecurityQuestion extends LightningElement {
    labels = { title, securityQuestions, answer, verify, useDifferentQuestion, chooseAnotherMethod };

    @api questions = [];

    @track currentQuestion;
    @track answerInput = '';

    connectedCallback() {
        this.currentQuestion = this.pickRandom(this.questions);
    }

    pickRandom(pool) {
        if (!pool || pool.length === 0) return null;
        const idx = Math.floor(Math.random() * pool.length);
        return pool[idx];
    }

    handleAnswerChange(event) {
        this.answerInput = event.target.value;
    }

    get isInvalid() {
        return !this.answerInput || this.answerInput.trim().length === 0;
    }

    handleSwap() {
        // Pick from remaining (excluding current)
        const remaining = this.questions.filter(
            q => q.question !== this.currentQuestion.question
        );
        if (remaining.length > 0) {
            this.currentQuestion = this.pickRandom(remaining);
            this.answerInput = '';
        }
    }

    handleVerify() {
        if (this.isInvalid) return;
        this.dispatchEvent(new CustomEvent('submit', {
            detail: {
                answer: {
                    question: this.currentQuestion.question,
                    answer: this.answerInput
                }
            }
        }));
    }

    handleSwitch() {
        this.dispatchEvent(new CustomEvent('switch'));
    }
}