/**
 * Tests for OAP_PhoneRegionUtil.
 *
 * No DML: the class only reads the picklist describe, and inserting an
 * Account with a country code is what surfaced the original bug (a
 * label-shaped value fails the restricted picklist). Values are asserted
 * through the API Names, which is what Apex and SOQL actually return.
 */
@IsTest
private class OAP_PhoneRegionUtilTest {

    @IsTest
    static void testApiNamesResolveToDialCodes() {
        Assert.areEqual('+1', OAP_PhoneRegionUtil.extractDialCode('CAN'));
        Assert.areEqual('+44', OAP_PhoneRegionUtil.extractDialCode('UK'));
        Assert.areEqual('+91', OAP_PhoneRegionUtil.extractDialCode('IND'));
        Assert.areEqual('+44', OAP_PhoneRegionUtil.extractDialCode('  uk '),
            'API Name should resolve case-insensitively and trimmed');
    }

    @IsTest
    static void testBlankAndOtherResolveToEmpty() {
        Assert.areEqual('', OAP_PhoneRegionUtil.extractDialCode(null));
        Assert.areEqual('', OAP_PhoneRegionUtil.extractDialCode('  '));
        Assert.areEqual('', OAP_PhoneRegionUtil.extractDialCode('OTH'),
            '"Other" has no dial code to give');
    }

    @IsTest
    static void testUnmappedValueResolvesToEmpty() {
        Assert.areEqual('', OAP_PhoneRegionUtil.extractDialCode('NOT_A_COUNTRY'));
        Assert.areEqual('', OAP_PhoneRegionUtil.extractDialCode('United Kingdom +44'),
            'A label is never a stored value, so it must not resolve');
    }

    @IsTest
    static void testDigitsOnlyStripsPlusAndFallsBack() {
        Assert.areEqual('44', OAP_PhoneRegionUtil.extractDialCodeDigitsOnly('UK', '1'));
        Assert.areEqual('1', OAP_PhoneRegionUtil.extractDialCodeDigitsOnly('OTH', '1'),
            'Fallback applies when there is no dial code');
        Assert.areEqual('1', OAP_PhoneRegionUtil.extractDialCodeDigitsOnly(null, '1'));
    }

    @IsTest
    static void testApiNameForDialCode() {
        Assert.areEqual('UK', OAP_PhoneRegionUtil.apiNameForDialCode('+44'));
        Assert.areEqual('UK', OAP_PhoneRegionUtil.apiNameForDialCode('44'),
            'A missing "+" should be tolerated');
        Assert.isNull(OAP_PhoneRegionUtil.apiNameForDialCode('+999'));
        Assert.isNull(OAP_PhoneRegionUtil.apiNameForDialCode(null));
    }
}
