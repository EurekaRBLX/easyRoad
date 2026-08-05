--!strict
-- Build-time product licensing. Default Commercial; --license oss → OSS.
-- OSS license for easyRoad is AGPL-3.0 (not MIT).

export type Mode = "Commercial" | "OSS"

local ProductLicense = {}

-- @EASYROAD_LICENSE_MODE@
ProductLicense.Mode = "Commercial" :: Mode

ProductLicense.EulaVersion = "1.0"
ProductLicense.Build = "0.1.0"
ProductLicense.OssLicenseName = "AGPL-3.0"

ProductLicense.WebBase = "https://v2.eurekarblx.com"
-- Future: ProductLicense.WebBaseFuture = "https://www.eurekarblx.com"
ProductLicense.TermsUrl = ProductLicense.WebBase .. "/terms"
ProductLicense.PrivacyUrl = ProductLicense.WebBase .. "/privacy"
ProductLicense.DiscordUrl = "https://discord.gg/srGUZ25jrz"
ProductLicense.DiscordHint = "Eureka Discord (" .. ProductLicense.DiscordUrl .. ")"

ProductLicense.SettingAccepted = "EasyRoadEulaAccepted"
ProductLicense.SettingVersion = "EasyRoadEulaVersion"

function ProductLicense.RequiresEula(): boolean
	return ProductLicense.Mode == "Commercial"
end

function ProductLicense.IsOss(): boolean
	return ProductLicense.Mode == "OSS"
end

ProductLicense.EulaTitle = "easyRoad End User License Agreement (\"EULA\")"
ProductLicense.EulaBody = [[Version 1.0 · Effective 2026

This End User License Agreement ("EULA") is between Eureka ("Eureka", "we", "us") and You.

Product: easyRoad, a Roblox Studio plugin ("Software")
You: the person or entity that installs, loads, or uses the Software

1. ACCEPTANCE
By clicking Agree, installing, loading, or using the Software, You confirm that You have read, acknowledge, and agree to:
(a) this easyRoad EULA;
(b) Eureka Terms & Conditions at https://v2.eurekarblx.com/terms; and
(c) Eureka Privacy Policy at https://v2.eurekarblx.com/privacy.
If You do not so agree, click Disagree and do not use the Software.

2. EARLY ACCESS
The Software is early access. Features may be incomplete, experimental, or change without notice. Compatibility with Roblox Studio or third-party assets is not guaranteed.
Eureka intends to open-source easyRoad later under the GNU Affero General Public License v3.0 (AGPL-3.0). That is a plan, not a fixed delivery date.

3. LICENSE GRANT (COMMERCIAL / EARLY PERIOD)
Subject to this EULA and any valid purchase or entitlement Eureka requires, Eureka grants You a limited, non-exclusive, non-transferable, revocable license to install and use the Software in Roblox Studio for Your own projects, solely in builds Eureka distributes to You. No other rights are granted by implication.

4. RESTRICTIONS
Except as Eureka allows in writing or mandatory law requires, You may not: redistribute or resell the commercial plugin package; remove notices; use the Software unlawfully or contrary to Roblox Terms; claim Eureka endorsement without permission.
Until Eureka publishes an official open-source release of the Software, You may not reverse engineer, decompile, disassemble, derive source, or otherwise attempt to discover the source code, structure, or ideas of the commercial Software, except only to the extent that such restriction is prohibited by mandatory applicable law. After an official open-source release, reverse-engineering and related rights for that open-source distribution are governed solely by AGPL-3.0 (which supersedes this EULA for that distribution).

5. OWNERSHIP
Eureka and its licensors retain all rights in the Software. This EULA does not sell the Software to You.

6. THIRD PARTIES
Roblox Studio use is subject to Roblox terms. Third-party assets remain under their own licenses. easyRoad does not grant those rights.

7. FUTURE OPEN SOURCE; SUPERSESSION
When Eureka publishes an official open-source release under AGPL-3.0: that license SUPERSEDES this EULA for users of the open-source distribution. Commercial builds may stay under this EULA until retired. Eureka will announce the open-source launch primarily via the Eureka Discord (https://discord.gg/srGUZ25jrz) and may also note it in Software / on the website.

8. UPDATES AND SUPPORT
Updates may change or remove features. Support is discretionary unless separately agreed in writing.

9. PAYMENT
If obtained via a paid channel, use may depend on a valid purchase or entitlement. Eureka may suspend access for fraud, chargebacks, or material breach.

10. DISCLAIMER
THE SOFTWARE IS PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTIES OF ANY KIND, TO THE MAXIMUM EXTENT PERMITTED BY LAW.

11. LIABILITY
TO THE MAXIMUM EXTENT PERMITTED BY LAW, EUREKA IS NOT LIABLE FOR ANY DAMAGES ARISING FROM THE SOFTWARE OR THIS EULA, INCLUDING INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR LOSS OF DATA, PROFITS, OR BUSINESS. Mandatory consumer rights are not excluded where they cannot be waived.

12. TERMINATION
This EULA ends if You breach it or stop using the Software. On termination, cease use and delete commercial copies under Your control. Survival: ownership, disclaimer, liability, governing law.

13. GOVERNING LAW
Subject to mandatory consumer protections, disputes are governed by the laws of the jurisdiction in which You reside (or, for a business, Your principal place of business).

14. CONTACT
Eureka · easyRoad · https://v2.eurekarblx.com · Discord: https://discord.gg/srGUZ25jrz

15. ENTIRE AGREEMENT
This EULA, with Eureka Terms and Privacy as they apply to You, is the agreement for the commercial Software.]]

return ProductLicense
