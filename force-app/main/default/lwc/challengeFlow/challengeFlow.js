/**
 * challengeFlow LWC
 * ---------------------------------------------------------------
 * Identity-verification component for the CFRIMS Challenge Flow.
 *
 * Screens (matching the UI mockups):
 *   1. Entry         – shows existing record info, "Start verification"
 *   2-4. Questions   – one security question at a time with Back/Next/Submit
 *   5. Success       – identity verified, route by application_completed
 *   6. Escalation    – contact CFRG (option 5)
 *   Direct route     – no challenge needed, welcome back
 */
import { LightningElement, api, track } from "lwc";
import evaluateMergeDecision from "@salesforce/apex/ChallengeFlowController.evaluateMergeDecision";
import verifySecurityQuestions from "@salesforce/apex/ChallengeFlowController.verifySecurityQuestions";
import verifyPersonalIdentifiers from "@salesforce/apex/ChallengeFlowController.verifyPersonalIdentifiers";
import verifyServiceNumber from "@salesforce/apex/ChallengeFlowController.verifyServiceNumber";
import verifyApplicantData from "@salesforce/apex/ChallengeFlowController.verifyApplicantData";
import { NavigationMixin } from "lightning/navigation";

const MAX_ATTEMPTS = 3;

// SHA-1 helper (Web Crypto API)
async function sha1Hex(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text.trim().toLowerCase());
    const hashBuffer = await crypto.subtle.digest("SHA-1", data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
}

export default class ChallengeFlow extends NavigationMixin(LightningElement) {
    /* ── Public API ── */

    /** JSON string of the CFRIMS challenge payload */
    @api challengePayload;

    /** Dashboard page reference (community page name) */
    @api dashboardPageRef = "Home";

    /** Resume application page reference */
    @api resumePageRef = "application-form";

    /* ── Tracked state ── */

    @track isLoading = true;

    // Screens
    @track currentScreen = "loading"; // loading | entry | question | success | escalation | direct

    // Merge decision result from Apex
    @track decision = {};

    // Questions
    @track questions = [];
    @track answers = [];
    @track currentQuestionIndex = 0;

    // Attempts
    @track currentAttempt = 1;

    // Verification result
    @track nextRoute = null; // dashboard | resume | escalate
    @track applicationCompletedFlag = 0;

    // Error
    @track errorMessage = null;

    // Submitting state
    @track isSubmitting = false;

    /* ── Lifecycle ── */

    connectedCallback() {
        this.initialise();
    }

    async initialise() {
        try {
            this.isLoading = true;

            if (!this.challengePayload) {
                // No payload provided; nothing to verify
                this.currentScreen = "direct";
                this.nextRoute = "dashboard";
                this.isLoading = false;
                return;
            }

            // Parse payload locally to extract application_completed
            try {
                const parsed = JSON.parse(this.challengePayload);
                this.applicationCompletedFlag = parsed.application_completed || 0;
            } catch (e) {
                // Will be caught by Apex too
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
                this.currentScreen = "entry";
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

    /* ── Computed properties ── */

    get showEntryScreen() {
        return !this.isLoading && this.currentScreen === "entry";
    }
    get showQuestionScreen() {
        return !this.isLoading && this.currentScreen === "question";
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

    get existingRecordLabel() {
        return this.decision.existingRecordLabel || "";
    }

    get totalQuestions() {
        return this.questions.length;
    }

    get maxAttempts() {
        return MAX_ATTEMPTS;
    }

    get currentQuestionDisplay() {
        return this.currentQuestionIndex + 1;
    }

    get currentScreenNumber() {
        return this.currentQuestionIndex + 2; // Screen 2, 3, 4 ...
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
        return this.isSubmitting ? "Verifying\u2026" : "Submit";
    }

    get nextRouteLabel() {
        if (this.nextRoute === "dashboard") return "Dashboard";
        if (this.nextRoute === "resume") return "Resume application";
        return "Dashboard";
    }

    get alphaNumber() {
        try {
            const parsed = JSON.parse(this.challengePayload);
            return parsed.Applicant_data?.personal_info?.alpha_nb || "—";
        } catch (e) {
            return "—";
        }
    }

    get progressSegments() {
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

    /* ── Event handlers ── */

    handleStartVerification() {
        this.currentQuestionIndex = 0;
        this.errorMessage = null;
        this.currentScreen = "question";
    }

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

    async handleSubmitAnswers() {
        this.isSubmitting = true;
        this.errorMessage = null;

        try {
            // Hash each answer client-side (SHA-1, uppercase hex)
            const hashed = await Promise.all(
                this.answers.map((a) => sha1Hex(a))
            );

            const result = await verifySecurityQuestions({
                payloadJson: this.challengePayload,
                answersJson: JSON.stringify(hashed),
                attemptNumber: this.currentAttempt,
            });

            if (result.passed) {
                this.nextRoute = result.nextRoute;
                this.currentScreen = "success";
            } else if (result.nextRoute === "escalate") {
                this.currentScreen = "escalation";
            } else {
                this.currentAttempt++;
                this.errorMessage = result.message;
                // Reset to first question for retry
                this.currentQuestionIndex = 0;
                this.answers = this.questions.map(() => "");
            }
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isSubmitting = false;
        }
    }

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
        // Navigate to a recruiter finder page or external URL
        this[NavigationMixin.Navigate]({
            type: "standard__webPage",
            attributes: {
                url: "https://forces.ca/en/talk-to-a-recruiter/",
            },
        });
    }

    /* ── Utilities ── */

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
