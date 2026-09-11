public with sharing class ChallengeOptionResolver {

    public static List<OAP_Cfrims2AvailableOption> resolve(CasePayload p) {
        List<OAP_Cfrims2AvailableOption> options = new List<OAP_Cfrims2AvailableOption>();
        if (p == null) {
            options.add(new OAP_Cfrims2AvailableOption('5', System.Label.OAP_Challenge_Opt5_GetHelp));
            return options;
        }

        Integer opt1 = firstNonNull(p.option1, nestedOption(p, 1));
        Integer opt2 = firstNonNull(p.option2, nestedOption(p, 2));
        Integer opt3 = firstNonNull(p.option3, nestedOption(p, 3));
        Integer opt4 = firstNonNull(p.option4, nestedOption(p, 4));

        // Option 1 requires a phone in the payload — without one there is
        // nothing to send an SMS to, so requestSmsCode would only throw
        // "No phone number on file". Gate it like option 3 gates service_nb.
        if (opt1 == 1 && String.isNotBlank(p.phone)) {
            options.add(new OAP_Cfrims2AvailableOption('1', System.Label.OAP_Challenge_Opt1_SendCode));
        }
        if (opt2 == 1 && p.security_question != null && !p.security_question.isEmpty()) {
            options.add(new OAP_Cfrims2AvailableOption('2', System.Label.OAP_Challenge_Opt2_SecurityQuestion));
        }
        if (opt3 == 1 && String.isNotBlank(p.service_nb)) {
            options.add(new OAP_Cfrims2AvailableOption('3', System.Label.OAP_Challenge_Opt3_ServiceNumber));
        }
        if (opt4 == 1) {
            options.add(new OAP_Cfrims2AvailableOption('4', System.Label.OAP_Challenge_Opt4_BirthDetails));
        }

        options.add(new OAP_Cfrims2AvailableOption('5', System.Label.OAP_Challenge_Opt5_GetHelp));
        return options;
    }

    public static String preferredDefault(List<OAP_Cfrims2AvailableOption> options) {
        if (options == null || options.isEmpty()) {
            return '5';
        }
        Set<String> available = new Set<String>();
        for (OAP_Cfrims2AvailableOption o : options) {
            if (o != null && String.isNotBlank(o.code)) {
                available.add(o.code);
            }
        }
        for (String preferred : new List<String>{ '1', '2', '3', '4', '5' }) {
            if (available.contains(preferred)) return preferred;
        }
        return '5';
    }

    private static Integer firstNonNull(Integer a, Integer b) {
        return a != null ? a : b;
    }

    private static Integer nestedOption(CasePayload p, Integer which) {
        if (p.challenge_options == null) return null;
        switch on which {
            when 1 { return p.challenge_options.option1; }
            when 2 { return p.challenge_options.option2; }
            when 3 { return p.challenge_options.option3; }
            when 4 { return p.challenge_options.option4; }
            when else { return null; }
        }
    }
}
