--!strict
-- SPDX-License-Identifier: AGPL-3.0-only
-- The Eureka repository builds the AGPL version of easyRoad.

local LicenseNotices = require("./LicenseNotices")

-- Keep these fields for the existing setup and settings integrations.
export type Mode = "Commercial" | "OSS"

local ProductLicense = {}

-- @EASYROAD_LICENSE_MODE@
ProductLicense.Mode = "OSS" :: Mode

ProductLicense.Build = "1.2.0"
ProductLicense.OssLicenseName = "AGPL-3.0-only"
ProductLicense.SourceUrl = "https://github.com/EurekaRBLX/easyRoad"
ProductLicense.LicenseUrl = ProductLicense.SourceUrl .. "/blob/main/LICENSE"

ProductLicense.WebBase = "https://v2.eurekarblx.com"
ProductLicense.DiscordUrl = "https://discord.gg/srGUZ25jrz"
ProductLicense.DiscordHint = "Eureka Discord (" .. ProductLicense.DiscordUrl .. ")"

-- Compatibility fields for the inactive legacy EULA component.
-- This distribution does not require EULA acceptance or website policies.
ProductLicense.EulaVersion = ProductLicense.OssLicenseName
ProductLicense.SettingAccepted = "EasyRoadEulaAccepted"
ProductLicense.SettingVersion = "EasyRoadEulaVersion"
ProductLicense.TermsUrl = ProductLicense.LicenseUrl
ProductLicense.PrivacyUrl = ProductLicense.SourceUrl
ProductLicense.EulaTitle = "GNU Affero General Public License, version 3"
ProductLicense.EulaBody = LicenseNotices.AGPL

function ProductLicense.RequiresEula(): boolean
	return false
end

function ProductLicense.IsOss(): boolean
	return true
end

return ProductLicense
