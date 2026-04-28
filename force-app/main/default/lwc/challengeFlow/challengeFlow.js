/**
 * challengeFlow LWC
 * ---------------------------------------------------------------
 * Identity-verification component for the CFRIMS Challenge Flow.
 *
 * Supports all 4 verification options with automatic fallback:
 *   Option 1 - Security Questions (SHA-1 hashed answers)
 *   Option 2 - Personal Identifiers (DOB, phone, last name, city of birth)
 *   Option 3 - Service Number
 *   Option 4 - Applicant Data (given name, alpha number)
 *   Option 5 - Escalation to CFRG (when all options exhausted)
 *
 * Screens:
 *   entry      - shows existing record, current method, "Start verification"
 *   option1    - one security question at a time with progress bar
 *   option2    - personal identifiers form
 *   option3    - service number input
 *   option4    - applicant data form (given name + alpha number)
 *   success    - identity verified, route by application_completed
 *   escalation - contact CFRG
 *   direct     - no challenge needed, welcome back
 */
import { LightningElement, api } from "lwc";
import evaluateMergeDecision from "@salesforce/apex/ChallengeFlowController.evaluateMergeDecision";
import verifySecurityQuestions from "@salesforce/apex/ChallengeFlowController.verifySecurityQuestions";
import verifyPersonalIdentifiers from "@salesforce/apex/ChallengeFlowController.verifyPersonalIdentifiers";
import verifyServiceNumber from "@salesforce/apex/ChallengeFlowController.verifyServiceNumber";
import verifyApplicantData from "@salesforce/apex/ChallengeFlowController.verifyApplicantData";
import { NavigationMixin } from "lightning/navigation";

const MAX_ATTEMPTS = 3;

const METHOD_LABELS = {
    1: "Security questions",
    2: "Personal information",
    3: "Service number",
    4: "Applicant details",
};

// SHA-1 helper (Web Crypto API)
async function sha1Hex(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text.trim().toLowerCase());
    const hashBuffer = await crypto.subtle.digest("SHA-1", data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("")
        .toUpperCase();
}

export default class ChallengeFlow extends NavigationMixin(LightningElement) {
    /* -- Public API -- */

    /** JSON string of the CFRIMS challenge payload */
    @api challengePayload;

    /** Dashboard page reference (community page name) */
    @api dashboardPageRef = "Home";

    /** Resume application page reference */
    @api resumePageRef = "application-form";

    /* -- Internal state -- */

    isLoading = true;

    // Screen: loading | entry | option1 | option2 | option3 | option4 | success | escalation | direct
    currentScreen = "loading";

    // Merge decision result from Apex
    decision = {};

    // Parsed payload (cached once)
    _parsedPayload = null;

    // Option cycling (mirrors React availableOptions + optionIndex)
    availableOptions = [];
    optionIndex = 0;

    // Security questions (Option 1)
    questions = [];
    answers = [];
    currentQuestionIndex = 0;

    // Option 2 fields
    opt2Dob = "";
    opt2Phone = "";
    opt2LastName = "";
    opt2CityBirth = "";

    // Option 3 field
    opt3ServiceNb = "";

    // Option 4 fields
    opt4GivenName = "";
    opt4AlphaNb = "";

    // Attempts (per option)
    currentAttempt = 1;

    // Routing
    nextRoute = null;
    applicationCompletedFlag = 0;

    // UI state
    errorMessage = null;
    isSubmitting = false;

    /* -- Lifecycle -- */

    connectedCallback() {
        this.initialise();
    }

    async initialise() {
        try {
            this.isLoading = true;

            if (!this.challengePayload) {
                this.currentScreen = "direct";
                this.nextRoute = "dashboard";
                this.isLoading = false;
                return;
            }

            // Cache the parsed payload
            try {
                this._parsedPayload = JSON.parse(this.challengePayload);
                this.applicationCompletedFlag =
                    this._parsedPayload.application_completed || 0;
            } catch (_e) {
                /* Apex will also validate */
            }

            const result = await evaluateMergeDecision({
                payloadJson: this.challengePayload,
            });

            this.decision = result;

            if (result.noMergeNeeded) {
                this.currentScreen = "direct";
                this.nextRoute = result.directRoute;
            } else if (result.showChallenge) {
                this.questions = result.questions || [];
                this.answers = this.questions.map(() => "");
                this.availableOptions = result.availableOptions || [];

                if (this.availableOptions.length === 0) {
                    this.currentScreen = "escalation";
                } else {
                    this.optionIndex = 0;
                    this.currentScreen = "entry";
                }
            } else {
                this.currentScreen = "direct";
                this.nextRoute = "dashboard";
            }
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
            this.currentScreen = "entry";
        } finally {
            this.isLoading = false;
        }
    }

    /* -- Screen visibility getters -- */

    get showEntryScreen() {
        return !this.isLoading && this.currentScreen === "entry";
    }
    get showOption1Screen() {
        return !this.isLoading && this.currentScreen === "option1";
    }
    get showOption2Screen() {
        return !this.isLoading && this.currentScreen === "option2";
    }
    get showOption3Screen() {
        return !this.isLoading && this.currentScreen === "option3";
    }
    get showOption4Screen() {
        return !this.isLoading && this.currentScreen === "option4";
    }
    get showSuccessScreen() {
        return !this.isLoading && this.currentScreen === "success";
    }
    get showEscalationScreen() {
        return !this.isLoading && this.currentScreen === "escalation";
    }
    get showDirectRoute() {
        return !this.isLoading && this.currentScreen === "direct";
    }

    /* -- Current option helpers -- */

    get currentOption() {
        return this.availableOptions[this.optionIndex] || null;
    }

    get currentMethodLabel() {
        return METHOD_LABELS[this.currentOption] || "";
    }

    get currentStepDisplay() {
        return this.optionIndex + 1;
    }

    get totalSteps() {
        return this.availableOptions.length;
    }

    get existingRecordLabel() {
        return this.decision.existingRecordLabel || "";
    }

    get maxAttempts() {
        return MAX_ATTEMPTS;
    }

    get alphaNumber() {
        if (this._parsedPayload) {
            const appData = this._parsedPayload.Applicant_data;
            if (appData && appData.personal_info) {
                return appData.personal_info.alpha_nb || "\u2014";
            }
        }
        return "\u2014";
    }

    get applicationCompletedDisplay() {
        return this.applicationCompletedFlag;
    }

    get nextRouteLabel() {
        if (this.nextRoute === "dashboard") return "Dashboard";
        if (this.nextRoute === "resume") return "Resume application";
        return "Dashboard";
    }

    /* -- Option step indicator -- */

    get optionStepSegments() {
        const segments = [];
        for (let i = 0; i < this.availableOptions.length; i++) {
            segments.push({
                key: "opt-" + i,
                className:
                    "progress-segment" +
                    (i < this.optionIndex
                        ? " completed"
                        : i === this.optionIndex
                        ? " active"
                        : ""),
            });
        }
        return segments;
    }

    get availableMethodsList() {
        return this.availableOptions.map((o) => ({
            key: "method-" + o,
            label: "Method " + o + " (" + (METHOD_LABELS[o] || "") + ")",
            isCurrent: o === this.currentOption,
            className:
                o === this.currentOption
                    ? "method-item current"
                    : "method-item",
        }));
    }

    /* -- Option 1 (security questions) getters -- */

    get totalQuestions() {
        return this.questions.length;
    }

    get currentQuestionDisplay() {
        return this.currentQuestionIndex + 1;
    }

    get currentQuestionText() {
        if (this.questions[this.currentQuestionIndex]) {
            return this.questions[this.currentQuestionIndex].question;
        }
        return "";
    }

    get currentAnswer() {
        return this.answers[this.currentQuestionIndex] || "";
    }

    get isFirstQuestion() {
        return this.currentQuestionIndex === 0;
    }

    get isLastQuestion() {
        return this.currentQuestionIndex === this.questions.length - 1;
    }

    get isAnswerEmpty() {
        const ans = this.answers[this.currentQuestionIndex];
        return !ans || ans.trim().length === 0;
    }

    get submitButtonLabel() {
        return this.isSubmitting ? "Verifying\u2026" : "Verify";
    }

    get questionProgressSegments() {
        const segments = [];
        for (let i = 0; i < this.totalQuestions; i++) {
            segments.push({
                key: "seg-" + i,
                className:
                    "progress-segment" +
                    (i < this.currentQuestionIndex
                        ? " completed"
                        : i === this.currentQuestionIndex
                        ? " active"
                        : ""),
            });
        }
        return segments;
    }

    /* -- Option 2 getters -- */

    get isOpt2SubmitDisabled() {
        return (
            this.isSubmitting ||
            !this.opt2Dob.trim() ||
            !this.opt2Phone.trim() ||
            !this.opt2LastName.trim() ||
            !this.opt2CityBirth.trim()
        );
    }

    /* -- Option 3 getters -- */

    get isOpt3SubmitDisabled() {
        return this.isSubmitting || !this.opt3ServiceNb.trim();
    }

    /* -- Option 4 getters -- */

    get isOpt4SubmitDisabled() {
        return (
            this.isSubmitting ||
            !this.opt4GivenName.trim() ||
            !this.opt4AlphaNb.trim()
        );
    }

    /* -- Event handlers -- */

    handleStartVerification() {
        this.errorMessage = null;
        this._showCurrentOptionScreen();
    }

    // --- Option 1 handlers ---

    handleAnswerChange(event) {
        const newAnswers = [...this.answers];
        newAnswers[this.currentQuestionIndex] = event.target.value;
        this.answers = newAnswers;
    }

    handleBack() {
        if (this.currentQuestionIndex > 0) {
            this.currentQuestionIndex--;
            this.errorMessage = null;
        }
    }

    handleNext() {
        if (this.currentQuestionIndex < this.questions.length - 1) {
            this.currentQuestionIndex++;
            this.errorMessage = null;
        }
    }

    async handleSubmitOption1() {
        this.isSubmitting = true;
        this.errorMessage = null;

        try {
            const hashed = await Promise.all(
                this.answers.map((a) => sha1Hex(a))
            );

            const result = await verifySecurityQuestions({
                payloadJson: this.challengePayload,
                answersJson: JSON.stringify(hashed),
                attemptNumber: this.currentAttempt,
            });

            this._handleVerificationResult(result);
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    // --- Option 2 handlers ---

    handleOpt2DobChange(event) {
        this.opt2Dob = event.target.value;
    }
    handleOpt2PhoneChange(event) {
        this.opt2Phone = event.target.value;
    }
    handleOpt2LastNameChange(event) {
        this.opt2LastName = event.target.value;
    }
    handleOpt2CityBirthChange(event) {
        this.opt2CityBirth = event.target.value;
    }

    async handleSubmitOption2() {
        this.isSubmitting = true;
        this.errorMessage = null;

        try {
            const result = await verifyPersonalIdentifiers({
                payloadJson: this.challengePayload,
                dob: this.opt2Dob,
                phone: this.opt2Phone,
                lastName: this.opt2LastName,
                cityBirth: this.opt2CityBirth,
                attemptNumber: this.currentAttempt,
            });

            this._handleVerificationResult(result);
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    // --- Option 3 handlers ---

    handleOpt3ServiceNbChange(event) {
        this.opt3ServiceNb = event.target.value.toUpperCase();
    }

    async handleSubmitOption3() {
        this.isSubmitting = true;
        this.errorMessage = null;

        try {
            const result = await verifyServiceNumber({
                payloadJson: this.challengePayload,
                serviceNb: this.opt3ServiceNb.trim(),
                attemptNumber: this.currentAttempt,
            });

            this._handleVerificationResult(result);
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    // --- Option 4 handlers ---

    handleOpt4GivenNameChange(event) {
        this.opt4GivenName = event.target.value;
    }
    handleOpt4AlphaNbChange(event) {
        this.opt4AlphaNb = event.target.value.toUpperCase();
    }

    async handleSubmitOption4() {
        this.isSubmitting = true;
        this.errorMessage = null;

        try {
            const result = await verifyApplicantData({
                payloadJson: this.challengePayload,
                givenName: this.opt4GivenName,
                alphaNb: this.opt4AlphaNb,
                attemptNumber: this.currentAttempt,
            });

            this._handleVerificationResult(result);
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    // --- Navigation handlers ---

    handleContinue() {
        const pageName =
            this.nextRoute === "resume"
                ? this.resumePageRef
                : this.dashboardPageRef;

        this[NavigationMixin.Navigate]({
            type: "comm__namedPage",
            attributes: {
                name: pageName,
            },
        });
    }

    handleFindRecruiter() {
        this[NavigationMixin.Navigate]({
            type: "standard__webPage",
            attributes: {
                url: "https://forces.ca/en/talk-to-a-recruiter/",
            },
        });
    }

    /* -- Private helpers -- */

    /**
     * Central handler for all verification results.
     * Mirrors the React handleFailure() / handleSubmit() logic:
     *   - passed -> success screen
     *   - failed + attempts remaining -> retry current option
     *   - failed + no attempts -> advance to next option or escalate
     */
    _handleVerificationResult(result) {
        if (result.passed) {
            this.nextRoute = result.nextRoute;
            this.currentScreen = "success";
        } else if (result.attemptsRemaining <= 0) {
            this._advanceToNextOption();
        } else {
            this.currentAttempt++;
            this.errorMessage = result.message;

            // Reset Option 1 form for retry
            if (this.currentOption === 1) {
                this.currentQuestionIndex = 0;
                this.answers = this.questions.map(() => "");
            }
        }
    }

    /**
     * Move to the next available option, or escalate if none remain.
     * Mirrors the React handleFailure() when attempts >= MAX_ATTEMPTS.
     */
    _advanceToNextOption() {
        if (this.optionIndex + 1 < this.availableOptions.length) {
            this.optionIndex++;
            this.currentAttempt = 1;
            this.errorMessage =
                "Verification failed. Trying an alternate method.";
            this._resetOptionForms();
            this._showCurrentOptionScreen();
        } else {
            this.currentScreen = "escalation";
        }
    }

    /**
     * Set the screen to the current option's screen name.
     */
    _showCurrentOptionScreen() {
        const opt = this.currentOption;
        if (opt >= 1 && opt <= 4) {
            this.currentScreen = "option" + opt;
        } else {
            this.currentScreen = "escalation";
        }
    }

    /**
     * Reset all option form fields for a fresh option attempt.
     */
    _resetOptionForms() {
        this.currentQuestionIndex = 0;
        this.answers = this.questions.map(() => "");
        this.opt2Dob = "";
        this.opt2Phone = "";
        this.opt2LastName = "";
        this.opt2CityBirth = "";
        this.opt3ServiceNb = "";
        this.opt4GivenName = "";
        this.opt4AlphaNb = "";
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return "An unexpected error occurred.";
    }
}
