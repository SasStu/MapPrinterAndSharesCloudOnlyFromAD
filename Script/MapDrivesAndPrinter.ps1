[cmdletbinding()]
param(
	$ADGroupPrefix = @{
			Printer = 'RIG-PRT-'
			Share   = 'RIG-MEM-FS-'
	},
	$GroupMappingProperty = 'info',
	$HomeShareMappingProperty = 'extensionattribute3',
	$HomeShareMappingMountPoint = 'H',
	$ADDelimiter = ';',
	$ADDomain = 'contoso.com',
	[int[]]$ADPort = @(389, 636),
	$LogfilePath = $env:LOCALAPPDATA + '\MapPrinterAndShares\MapFromMWP.log'
)

<#
.SYNOPSIS
Maps network drives and printers for the signed-in user based on their Active Directory group
memberships, on Entra-joined (cloud-only) devices whose signed-in user can authenticate to on-prem AD.

.DESCRIPTION
Resolves the current user's UPN from local registry caches, validated against the current Windows identity
and falling back to `whoami /upn` only as a last resort (see Resolve-UserPrincipalName), looks up the
matching on-prem AD user object via raw ADSI (no ActiveDirectory module dependency), recursively walks the
user's
memberOf chain for groups whose CN matches a configured prefix, and decodes each matched group's mapping
data ("<UNC path>;<mount point>", delimiter configurable) from an AD attribute. Shares are mapped with
`net.exe use /persistent:Yes`; printers via `Add-Printer -ConnectionName`. Mappings are additive: nothing
is ever removed by this script. If AD is unreachable, the script exits 0 quietly rather than failing.

Invoking this file directly runs the full workflow (Invoke-MapDrivesAndPrinter). Dot-sourcing it
(`. .\MapDrivesAndPrinter.ps1`) only defines the functions below, without running anything - this is how
the Pester test suite exercises the pure/boundary-mocked functions in isolation.

.PARAMETER ADGroupPrefix
Hashtable keyed by mapping type ('Printer', 'Share') whose values are the CN prefix that identifies a
group of that type. Matching is anchored to the start of the group's CN, not a substring match against
the full DN. Set a type's prefix to '' to skip that mapping type entirely.

.PARAMETER GroupMappingProperty
Name of the AD group attribute that holds the mapping data, formatted as "<UNC path><ADDelimiter><mount
point>" (the mount point segment is ignored/optional for Printer-type groups).

.PARAMETER HomeShareMappingProperty
Name of the user-level AD attribute (not a group attribute) that holds the user's home share UNC path, if
any. Leave unset/empty to skip home share mapping.

.PARAMETER HomeShareMappingMountPoint
Drive letter the home share is mapped to when HomeShareMappingProperty resolves to a valid UNC path.

.PARAMETER ADDelimiter
Delimiter separating the UNC path and mount point segments within a group's GroupMappingProperty value.

.PARAMETER ADDomain
DNS domain name of the on-prem Active Directory to bind against (e.g. 'contoso.com'), reached via LDAP as
the signed-in user with no stored credentials. AD reachability is pre-flighted before any LDAP call is
attempted - see ADPort.

.PARAMETER ADPort
TCP ports tried, in order, by the reachability pre-flight - default 389 (LDAP) then 636 (LDAPS). The first
port that answers wins; the pre-flight only reports AD unreachable when none of them do. This is purely a
connectivity probe: the bind itself is still made by ADSI over LDAP://, so a domain that only exposes 636
still counts as reachable here.

.PARAMETER LogfilePath
Path to the per-user transcript log. Rotated (keeping 3 prior generations) before each run.

.EXAMPLE
.\MapDrivesAndPrinter.ps1
Runs the full workflow for the currently signed-in user using the default parameters above - this is how
the Scheduled Task (Install/SMBShares.xml) invokes it.

.EXAMPLE
. .\MapDrivesAndPrinter.ps1
Dot-sources the script to load its functions into the current session without running anything, for
interactive testing or use from the Pester test suite.

.NOTES
Requires two prerequisites not shipped in this repo: an Intune NetworkListManager CSP profile that grants
the Domain firewall profile on network connect (ADR 0001), and the signed-in user being able to
authenticate to on-prem AD so the LDAP bind can succeed with no stored credentials (ADR 0002). The latter
is free for hybrid users signing in with username and password; passwordless sign-in (Windows Hello for
Business, FIDO2) needs Cloud Kerberos Trust or an equivalent trust model.
#>

<#
.SYNOPSIS
Rotates a log file, keeping a fixed number of prior generations.

.DESCRIPTION
If filePath exists, shifts filePath.<suffix>1 .. filePath.<suffix>(N-1) up by one generation (dropping the
oldest beyond fileRetentionCount), then renames the current file to filePath.<suffix>1. No-ops if filePath
does not exist yet. Throws on any rename/delete failure.

.PARAMETER filePath
Path to the active log file to rotate.

.PARAMETER fileRetentionCount
Number of prior generations to keep (default 3).

.PARAMETER suffix
Suffix used for rotated generations, e.g. filePath.OLD1 (default 'OLD').

.EXAMPLE
Invoke-LogRotation -filePath 'C:\Logs\app.log' -fileRetentionCount 3 -suffix 'old'
#>
function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$filePath,
        [int]$fileRetentionCount = 3,
        [string]$suffix = 'OLD'
    )
    begin {
        Write-Verbose -Message "Start function: $($MyInvocation.MyCommand.Name)"
    }
    process {
        if (Test-Path -Path $filePath) {
            Write-Verbose -Message "$($filePath) exists"
            # Remove the oldest file if it exists
            $oldest = "$($filePath).$($suffix)$($fileRetentionCount)"
            Write-Verbose -Message "Test if oldest file $($oldest) exists and will be deleted"
            if (Test-Path $oldest) {
                Write-Verbose -Message "Oldest file $($oldest) exists and will be deleted"
                try{
                    Remove-Item $oldest -Force
                    Write-Verbose -Message "Successfully deleted file $($oldest)"
                }
                catch{
                    Throw ("Error while deleting oldest file $($oldest) + ' Error message: ' + $_.Exception.Message")
                }
            }
            # Shift older files up
            for ($i = $fileRetentionCount - 1; $i -ge 1; $i--) {
                $src = "$filePath.$suffix$i"
                $dst = "$filePath.$suffix" + ($i + 1)
                Write-Verbose -Message "Test if file $($src) exists"
                if (Test-Path $src) {
                    Write-Verbose -Message "File $($src) exists"
                    try{
                        Write-Verbose -Message "Rename file $($src) to $($dst)"
                        Rename-Item -Path $src -NewName $dst
                        Write-Verbose -Message "Successfully renamed file $($src) to $($dst)"
                    }
                    catch{
                        Throw ("Error renaming file $($src) to $($dst)" + ' Error message: ' + $_.Exception.Message)
                    }
                }
            }
            # Rename current log to .OLD1
            try{
                Write-Verbose -Message "Rename file $($filePath) to $($filePath).$($suffix)1"
                Rename-Item -Path $filePath -NewName "$($filePath).$($suffix)1"
                Write-Verbose -Message "Successfully renamed file $($filePath) to $($filePath).$($suffix)1"
                }
            catch{
                Throw ("Error renaming file $($filePath) to $($filePath).$($suffix)1" + ' Error message: ' + $_.Exception.Message)
                }
        } else {
            Write-Verbose -Message "Log file path does not exist: $filePath"
        }
    }
    end {
        Write-Verbose -Message "End function: $($MyInvocation.MyCommand.Name)"
    }
}

<#
.SYNOPSIS
Recursively resolves a list of group DNs (from a memberOf-style property) down to the AD group objects
whose CN starts with a given search pattern.

.DESCRIPTION
For each DN in MemberOf, looks up the group via Get-ADSIObject, skips DNs already present in Visited
(preventing both re-processing diamond memberships and infinite loops on true membership cycles), and
includes the group in the result if its CN starts with SearchPattern (anchored match, not a substring
match against the DN). When -recurse is $true, also walks that group's own memberOf property the same
way, sharing the same Visited set across the whole recursive walk.

.PARAMETER MemberOf
Collection of group distinguishedNames to resolve, typically a user or group's memberOf property.

.PARAMETER SearchPattern
CN prefix a group must start with to be included in the result (e.g. 'RIG-PRT-').

.PARAMETER recurse
When $true, also walks nested group memberships using the same SearchPattern and Visited set.

.PARAMETER Visited
Case-insensitive set of DNs already processed in this walk; pass explicitly only when composing multiple
calls that should share cycle/diamond protection. Defaults to a fresh set per top-level call.

.OUTPUTS
Zero or more AD group result objects (as returned by Get-ADSIObject) whose CN matches SearchPattern.

.EXAMPLE
Get-MemberOfMappings -MemberOf $UserObject.Properties.memberof -SearchPattern 'RIG-PRT-' -recurse $true
#>
function Get-MemberOfMappings {
	[CmdletBinding()]
	param(
		$MemberOf,
		$SearchPattern,
		$recurse,
		[System.Collections.Generic.HashSet[string]]$Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	)
	begin {
		Write-Verbose -Message "Start function: $($MyInvocation.MyCommand.Name)"
		Write-Verbose -Message "Line: $($MyInvocation.Line)"
		$retArray = @()
		$anchoredPattern = '^' + [regex]::Escape($SearchPattern)
	}
	process {
		Write-Verbose ('Processing MemberOf: ' + $MemberOf)
		foreach ($DN in $MemberOf) {
			if ($Visited.Contains($DN)) {
				Write-Verbose ('Already visited group, skipping: ' + $DN)
				continue
			}
			$Visited.Add($DN) | Out-Null

			Write-Verbose ('Processing membership group: ' + $DN)
			$GroupResults = @(Get-ADSIObject -LDAPFilter "(&(objectClass=group)(distinguishedName=$($DN)))" -SearchRoot ([ADSI] "LDAP://$($ADDomain)"))
			if ($GroupResults.Count -eq 0) {
				Write-Warning ('Could not find group: ' + $DN)
				continue
			}
			$GroupObject = $GroupResults[0]
			if ($GroupObject.Properties.cn -match $anchoredPattern) {
				Write-Verbose ('Group CN matches search pattern: ' + $SearchPattern)
				$retArray += $GroupObject
			}
			if ($recurse -eq $true) {
				Write-Verbose ('Recurse is set to true, checking for nested groups')
				if ($GroupObject.Properties.memberof) {
					Write-Verbose ('Group has memberof property, checking for nested groups')
					$retArray += Get-MemberOfMappings -MemberOf $GroupObject.Properties.memberof -SearchPattern $SearchPattern -recurse $true -Visited $Visited
				}
			}
		}
	}
	end {
		Write-Verbose -Message "End function: $($MyInvocation.MyCommand.Name)"
		$retArray
	}
}
<#
.SYNOPSIS
Finds the next free drive letter, starting from a requested letter and cycling forward through the
alphabet (wrapping Z back to A once).

.DESCRIPTION
Pure function: given a requested letter and a list of letters already considered unavailable, returns the
first free letter starting at Requested and cycling forward (A-Z, wrapping once). Returns $null if all 26
letters are unavailable. Comparison is case-insensitive.

.PARAMETER Requested
The preferred single drive letter to start searching from.

.PARAMETER UnavailableMountPoints
Letters to treat as already taken (e.g. drives in use on the device plus ones already claimed earlier in
the same run).

.OUTPUTS
A single uppercase drive letter, or $null if none are free.

.EXAMPLE
Get-AvailableMountPoint -Requested 'H' -UnavailableMountPoints @('H', 'I')
# Returns 'J'
#>
function Get-AvailableMountPoint {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[ValidatePattern('^[A-Za-z]$')]
		[string]$Requested,

		[string[]]$UnavailableMountPoints = @()
	)
	$unavailable = @($UnavailableMountPoints | ForEach-Object { $_.ToUpper() })
	$start = [byte][char]$Requested.ToUpper()[0]
	for ($offset = 0; $offset -lt 26; $offset++) {
		$letter = [string][char](65 + (($start - 65 + $offset) % 26))
		if ($unavailable -notcontains $letter) {
			return $letter
		}
	}
	return $null
}

<#
.SYNOPSIS
Parses and validates a single group mapping value ("<UNC path><Delimiter><mount point>") into a
structured, validated request.

.DESCRIPTION
Pure function: splits Description on Delimiter into a path and mount-point segment. Requires the path
segment to look UNC-shaped (\\server\share...). For Type 'Share', additionally requires the mount-point
segment to be a single letter; for Type 'Printer', the mount-point segment is discarded (irrelevant) even
if present. Never throws - malformed input comes back with IsValid = $false and a human-readable
ValidationError describing what was wrong, so the caller can warn and skip rather than fail the whole run.

.PARAMETER Type
Either 'Share' or 'Printer' - determines whether a mount-point segment is required.

.PARAMETER Description
Raw attribute value to parse, e.g. '\\fs01\finance;F'. May be an empty string.

.PARAMETER Delimiter
Delimiter separating the path and mount-point segments (default ';').

.OUTPUTS
A [pscustomobject] with Type, Path, MountPoint, IsValid, and ValidationError properties.

.EXAMPLE
Resolve-MappingGroupDescription -Type Share -Description '\\fs01\finance;F' -Delimiter ';'
#>
function Resolve-MappingGroupDescription {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[ValidateSet('Share', 'Printer')]
		[string]$Type,

		[AllowEmptyString()]
		[string]$Description,

		[string]$Delimiter = ';'
	)
	$segments = $Description -split [regex]::Escape($Delimiter)
	$path = $segments[0]
	$mountPoint = $segments[1]

	$validationError = $null
	if ($path -notmatch '^\\\\[^\\]+\\[^\\]+') {
		$validationError = "Path '$path' is not a valid UNC path"
	}
	elseif ($Type -eq 'Share') {
		if ($mountPoint -notmatch '^[A-Za-z]$') {
			$validationError = "MountPoint '$mountPoint' is not a single drive letter"
		}
	}
	else {
		$mountPoint = ''
	}

	[pscustomobject]@{
		Type            = $Type
		Path            = $path
		MountPoint      = $mountPoint
		IsValid         = ($null -eq $validationError)
		ValidationError = $validationError
	}
}

<#
.SYNOPSIS
Builds the deduplicated list of mapping requests (shares and printers) for a user, from their resolved AD
groups plus an optional home share attribute.

.DESCRIPTION
Pure function: no AD/SMB calls of its own, operates entirely on already-fetched data. Starts with the
user's home share (if HomeShareMappingProperty/HomeShareMappingMountPoint are supplied and the property
value is UNC-shaped) as a Share request. Then, for every group under each Type key of ADGroup, parses its
GroupMappingProperty value via Resolve-MappingGroupDescription; groups with an empty mapping property or a
malformed value are skipped with a Write-Warning naming the group's CN, not fatal to the run. Results are
deduplicated by "Type|Path" - the same share/printer reached through two different group memberships (e.g.
nested/diamond membership) only produces one request.

.PARAMETER UserObject
The resolved AD user object (as returned by Get-ADSIObject), used to read HomeShareMappingProperty.

.PARAMETER ADGroup
Hashtable keyed by mapping type ('Share', 'Printer') whose values are arrays of resolved AD group objects
for that type, as produced by Get-MemberOfMappings.

.PARAMETER GroupMappingProperty
Name of the AD group attribute holding the mapping value (default 'description').

.PARAMETER ADDelimiter
Delimiter separating the path and mount-point segments within a group's mapping value (default ';').

.PARAMETER HomeShareMappingProperty
Name of the user-level attribute holding the home share UNC path, if home share mapping is enabled.

.PARAMETER HomeShareMappingMountPoint
Drive letter to request for the home share, if home share mapping is enabled.

.OUTPUTS
An array of [pscustomobject] with Type, Path, and MountPoint properties - MountPoint is empty for Printer
requests and not yet conflict-resolved for Share requests (see Resolve-ShareMountPointAssignment).

.EXAMPLE
Resolve-ObjectsToMap -UserObject $UserObject -ADGroup $ADGroup -GroupMappingProperty 'info' -ADDelimiter ';' -HomeShareMappingProperty 'extensionattribute3' -HomeShareMappingMountPoint 'H'
#>
function Resolve-ObjectsToMap {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		$UserObject,

		[Parameter(Mandatory)]
		[hashtable]$ADGroup,

		[string]$GroupMappingProperty = 'description',
		[string]$ADDelimiter = ';',
		[string]$HomeShareMappingProperty,
		[string]$HomeShareMappingMountPoint
	)
	$seen = @{}
	$results = @()

	if ($HomeShareMappingProperty -and $HomeShareMappingMountPoint -and $UserObject.Properties.$HomeShareMappingProperty) {
		$homePath = [string]$UserObject.Properties.$HomeShareMappingProperty
		if ($homePath -match '^\\\\[^\\]+\\[^\\]+') {
			$key = "Share|$homePath"
			$seen[$key] = $true
			$results += [pscustomobject]@{ Type = 'Share'; Path = $homePath; MountPoint = $HomeShareMappingMountPoint }
		}
		else {
			Write-Warning "HomeShareMappingProperty '$HomeShareMappingProperty' value '$homePath' is not a valid UNC path; skipping home share."
		}
	}

	foreach ($Type in $ADGroup.Keys) {
		foreach ($Group in $ADGroup.Item($Type)) {
			$rawDescription = $Group.Properties.$GroupMappingProperty
			if (-not $rawDescription) {
				Write-Warning ('AD Group: ' + $Group.Properties.cn + ' GroupMappingProperty ' + $GroupMappingProperty + ' is empty')
				continue
			}
			$resolved = Resolve-MappingGroupDescription -Type $Type -Description ([string]$rawDescription) -Delimiter $ADDelimiter
			if (-not $resolved.IsValid) {
				Write-Warning ('AD Group: ' + $Group.Properties.cn + ' has a malformed ' + $GroupMappingProperty + ': ' + $resolved.ValidationError)
				continue
			}
			$key = "$Type|$($resolved.Path)"
			if ($seen.ContainsKey($key)) {
				continue
			}
			$seen[$key] = $true
			$results += [pscustomobject]@{ Type = $Type; Path = $resolved.Path; MountPoint = $resolved.MountPoint }
		}
	}

	$results
}

<#
.SYNOPSIS
Assigns real, non-conflicting drive letters to the Share-type requests in a list of mapping requests.

.DESCRIPTION
Pure function: Printer-type requests pass through unchanged (MountPoint is meaningless for them). For each
Share-type request, calls Get-AvailableMountPoint starting from its requested letter, treating
InUseMountPoints plus every letter already claimed earlier in this same call as unavailable - so two share
requests in one run can never be assigned the same letter. A request that can't get a free letter is
dropped with a Write-Warning rather than failing the whole batch.

.PARAMETER Requests
Array of mapping requests (Type/Path/MountPoint), typically the output of Resolve-ObjectsToMap. May be
empty.

.PARAMETER InUseMountPoints
Letters already in use on the device (e.g. from Get-InUseMountPoint), treated as unavailable for every
Share request in this call.

.OUTPUTS
An array of [pscustomobject] with Type, Path, and MountPoint - Share entries have a resolved, conflict-free
MountPoint; Printer entries are unchanged; entries that couldn't get a mount point are omitted.

.EXAMPLE
Resolve-ShareMountPointAssignment -Requests $MappingRequests -InUseMountPoints (Get-InUseMountPoint)
#>
function Resolve-ShareMountPointAssignment {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[object[]]$Requests,

		[string[]]$InUseMountPoints = @()
	)
	$claimed = @($InUseMountPoints | ForEach-Object { $_.ToUpper() })
	$assigned = @()

	foreach ($request in $Requests) {
		if ($request.Type -ne 'Share') {
			$assigned += $request
			continue
		}
		$letter = Get-AvailableMountPoint -Requested $request.MountPoint -UnavailableMountPoints $claimed
		if ($null -eq $letter) {
			Write-Warning "No available mount point for share $($request.Path); requested '$($request.MountPoint)' and no free letters remain on this device."
			continue
		}
		$claimed += $letter
		$assigned += [pscustomobject]@{ Type = $request.Type; Path = $request.Path; MountPoint = $letter }
	}

	$assigned
}

<#
.SYNOPSIS
Returns the single-letter drive letters currently in use on this device.

.DESCRIPTION
Wraps Get-PSDrive -PSProvider FileSystem rather than Get-SmbMapping, so it also catches non-SMB drives
already occupying a letter (e.g. a USB stick sitting on H:), not just existing share mappings.

.OUTPUTS
An array of uppercase single-letter drive names currently present on the device.

.EXAMPLE
Get-InUseMountPoint
#>
function Get-InUseMountPoint {
	[CmdletBinding()]
	param()
	@(Get-PSDrive -PSProvider FileSystem) |
		Where-Object { $_.Name.Length -eq 1 } |
		ForEach-Object { $_.Name.ToUpper() }
}

<#
.SYNOPSIS
Returns the SamAccountName portion of the current process's Windows identity (e.g. 'jdoe' from
'CONTOSO\jdoe').

.DESCRIPTION
Thin adapter around [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, isolated into its own
function purely so it can be mocked by name in tests - the same boundary-function pattern used for
Get-ADSIObject, Invoke-NetUseCommand, etc.

.OUTPUTS
The SamAccountName portion (after any 'DOMAIN\') of the current Windows identity's Name.

.EXAMPLE
Get-CurrentSamAccountName
#>
function Get-CurrentSamAccountName {
	[CmdletBinding()]
	param()
	([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
}

<#
.SYNOPSIS
Runs 'whoami /upn' and returns its output, trimmed.

.DESCRIPTION
Boundary function for the whoami.exe fallback in Resolve-UserPrincipalName - isolated so tests can mock it
without actually spawning a process. Never throws; returns $null on any failure.

.OUTPUTS
The trimmed first line of 'whoami /upn' output, or $null if the command failed.

.EXAMPLE
Invoke-WhoamiUpnCommand
#>
function Invoke-WhoamiUpnCommand {
	[CmdletBinding()]
	param()
	try {
		$output = & "$env:SystemRoot\System32\whoami.exe" /upn 2>&1
		$first = ($output | Select-Object -First 1 | Out-String).Trim()
		if ($first) { $first } else { $null }
	}
	catch {
		$null
	}
}

<#
.SYNOPSIS
Resolves the current user's UPN from local, per-user registry caches, validated against the current
Windows identity, falling back to 'whoami /upn' only as a last resort.

.DESCRIPTION
Tries the SID-keyed IdentityStore cache first
(HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\<Sid>\IdentityCache\<Sid>\UserName), validating the value
against an anchored email-shaped regex. Falls back to the WorkplaceJoin\AADNGC key if that's absent or
didn't match the current user; since AADNGC can hold multiple subkeys, all candidate UserId values are
validated and a candidate is only considered when exactly one valid entry exists - an ambiguous
multi-candidate AADNGC logs a warning and is treated as no candidate, rather than risking an array
reaching an LDAP filter.

Every candidate UPN from either registry source is additionally required to match the current user: its
local-part (before '@') must equal Get-CurrentSamAccountName, case-insensitively. This catches a stale or
cross-account cache entry rather than trusting whichever UPN happens to be sitting in the registry. A
candidate that fails this check is discarded (with a warning) and resolution continues down the fallback
chain, exactly as if that source had found nothing.

Only if neither registry source yields a UPN matching the current user does this fall back to
Invoke-WhoamiUpnCommand ('whoami /upn'). This is deliberately a last resort, not a primary source: spawning
whoami.exe from a scheduled task is a pattern endpoint protection treats as reconnaissance and alerts on
(see ADR 0004) - acceptable as a rare fallback, not as the common path.

.PARAMETER Sid
The current user's SID (e.g. from [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value),
used to key into the IdentityStore cache path.

.OUTPUTS
The resolved UPN as a string, or $null if no source yields a UPN matching the current user.

.EXAMPLE
Resolve-UserPrincipalName -Sid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
#>
function Resolve-UserPrincipalName {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string]$Sid
	)
	$upnPattern = '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
	$currentSamAccountName = Get-CurrentSamAccountName

	$identityStorePath = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$Sid\IdentityCache\$Sid"
	if (Test-Path -Path $identityStorePath) {
		$upn = (Get-ItemProperty -Path $identityStorePath -Name 'UserName' -ErrorAction SilentlyContinue).UserName
		if ($upn -match $upnPattern) {
			if (($upn -split '@')[0] -eq $currentSamAccountName) {
				Write-Verbose "Resolved UPN from IdentityStore cache: $upn"
				return $upn
			}
			Write-Warning "IdentityStore cache UPN '$upn' does not match the current user ('$currentSamAccountName'); ignoring it."
		}
	}

	$workplaceJoinPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\AADNGC"
	if (Test-Path -Path $workplaceJoinPath) {
		$candidates = @(
			Get-ChildItem -Path $workplaceJoinPath -ErrorAction SilentlyContinue |
				ForEach-Object { (Get-ItemProperty -Path $_.PSPath -Name 'UserId' -ErrorAction SilentlyContinue).UserId } |
				Where-Object { $_ -match $upnPattern }
		)
		if ($candidates.Count -eq 1) {
			if (($candidates[0] -split '@')[0] -eq $currentSamAccountName) {
				Write-Verbose "Resolved UPN from WorkplaceJoin\AADNGC fallback: $($candidates[0])"
				return $candidates[0]
			}
			Write-Warning "WorkplaceJoin\AADNGC UPN '$($candidates[0])' does not match the current user ('$currentSamAccountName'); ignoring it."
		}
		elseif ($candidates.Count -gt 1) {
			Write-Warning "Multiple candidate UPNs found under WorkplaceJoin\AADNGC; cannot disambiguate: $($candidates -join ', ')"
		}
	}

	Write-Warning "No registry-cached UPN matched the current user; falling back to 'whoami /upn'."
	$whoamiUpn = Invoke-WhoamiUpnCommand
	if ($whoamiUpn -match $upnPattern) {
		Write-Verbose "Resolved UPN from whoami /upn fallback: $whoamiUpn"
		return $whoamiUpn
	}

	return $null
}

<#
.SYNOPSIS
Checks whether Active Directory appears reachable, via a short-timeout TCP connect to an LDAP port.

.DESCRIPTION
Attempts a raw TCP connection to ADDomain on each port in Port, in order (default 389 then 636), each with
a bounded timeout, and returns $true as soon as one of them connects. A domain controller that only
answers on LDAPS therefore still counts as reachable. Used as a cheap pre-flight before any real LDAP
call, so that on a device with no AD connectivity the script can exit quietly rather than hang or fail
noisily. Note the timeout is per port, so the worst case (nothing answering anywhere) is
TimeoutMilliseconds multiplied by the number of ports. Not further unit-testable without a real
reachable/unreachable endpoint (a raw TCP boundary, like Invoke-NetUseCommand) - manually verified:
returns $false after timing out against closed ports and $true immediately against an open one.

.PARAMETER ADDomain
DNS name or address to attempt the connection against.

.PARAMETER Port
TCP ports to try, in order (default 389 = LDAP, then 636 = LDAPS). The first one that answers wins.

.PARAMETER TimeoutMilliseconds
How long to wait for each port before moving on to the next one (default 2000). If no port answers within
its own window, the function returns $false.

.OUTPUTS
$true if a TCP connection to any of the ports succeeded within its timeout, otherwise $false.

.EXAMPLE
Test-ADReachable -ADDomain 'contoso.com'

.EXAMPLE
Test-ADReachable -ADDomain 'contoso.com' -Port 636
Probes LDAPS only, for a domain that does not expose 389 to clients.
#>
function Test-ADReachable {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string]$ADDomain,

		[int[]]$Port = @(389, 636),

		[int]$TimeoutMilliseconds = 2000
	)
	foreach ($CurrentPort in $Port) {
		$client = [System.Net.Sockets.TcpClient]::new()
		try {
			$connectTask = $client.ConnectAsync($ADDomain, $CurrentPort)
			if (-not $connectTask.Wait($TimeoutMilliseconds)) {
				Write-Verbose -Message "No answer from $($ADDomain):$($CurrentPort) within $($TimeoutMilliseconds)ms."
				continue
			}
			if ($client.Connected) {
				Write-Verbose -Message "AD reachable on $($ADDomain):$($CurrentPort)."
				return $true
			}
		}
		catch {
			Write-Verbose -Message "Connection to $($ADDomain):$($CurrentPort) failed: $($_.Exception.Message)"
		}
		finally {
			$client.Dispose()
		}
	}
	return $false
}

<#
.SYNOPSIS
Runs a raw ADSI DirectorySearcher query and returns all matching results.

.DESCRIPTION
Boundary function wrapping System.DirectoryServices.DirectorySearcher directly - no ActiveDirectory module
dependency. Sets ClientTimeout as defense in depth against AD becoming unreachable mid-run after
Test-ADReachable's pre-flight has already passed (relevant because the scheduled task's
MultipleInstancesPolicy=IgnoreNew plus ExecutionTimeLimit=PT1H means one stuck instance would otherwise
swallow every trigger for an hour). Not further unit-testable without a real LDAP connection - this is the
boundary the rest of the script's AD logic is mocked against in tests.

.PARAMETER LDAPFilter
LDAP filter string for the search, e.g. '(&(objectCategory=user)(userPrincipalName=jdoe@contoso.com))'.

.PARAMETER SearchRoot
The DirectoryEntry to search from, typically [ADSI]"LDAP://$ADDomain".

.PARAMETER ClientTimeoutSeconds
Timeout applied to the underlying DirectorySearcher.ClientTimeout (default 15).

.OUTPUTS
The SearchResultCollection returned by DirectorySearcher.FindAll() - empty, not $null, when no match.

.EXAMPLE
Get-ADSIObject -LDAPFilter "(&(objectCategory=user)(userPrincipalName=$UserUPN))" -SearchRoot ([ADSI] "LDAP://$ADDomain")
#>
function Get-ADSIObject {
	[cmdletbinding()]
	param(
		$LDAPFilter,
		$SearchRoot,
		[int]$ClientTimeoutSeconds = 15
	)
	Write-Verbose -Message "Start function: $($MyInvocation.MyCommand.Name)"
	Write-Verbose -Message "Line: $($MyInvocation.Line)"
	Write-Verbose -Message "LDAPFilter: $($LDAPFilter)"
	Write-Verbose -Message "SearchRoot: $($SearchRoot)"
	$Search = New-Object DirectoryServices.DirectorySearcher($LDAPFilter)
	$Search.SearchRoot = $SearchRoot
	$Search.ClientTimeout = [TimeSpan]::FromSeconds($ClientTimeoutSeconds)
	$Search.FindAll()
	Write-Verbose -Message "End function: $($MyInvocation.MyCommand.Name)"
}

<#
.SYNOPSIS
Maps a drive letter to a UNC path by invoking net.exe directly, persistently.

.DESCRIPTION
Boundary function: runs `net.exe use <letter>: <path> /persistent:Yes` directly (not via Start-Process),
checks $LASTEXITCODE, and captures net.exe's combined stdout/stderr verbatim rather than pattern-matching
its (localised) text. Never throws - failures come back as a result object with Success = $false, for the
caller to decide how to log. Not further unit-testable without really invoking net.exe; Add-ObjectMapping's
orchestration around it is tested by mocking this function.

.PARAMETER MountPoint
Single drive letter to map (case-insensitive; always used uppercase).

.PARAMETER Path
UNC path to map the drive to.

.OUTPUTS
A [pscustomobject] with Success, ExitCode, and Output (net.exe's trimmed combined output).

.EXAMPLE
Invoke-NetUseCommand -MountPoint 'F' -Path '\\fs01\finance'
#>
function Invoke-NetUseCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string]$MountPoint,

		[Parameter(Mandatory)]
		[string]$Path
	)
	try {
		$output = & "$env:SystemRoot\System32\net.exe" use "$($MountPoint.ToUpper()):" $Path '/persistent:Yes' 2>&1
		[pscustomobject]@{
			Success  = ($LASTEXITCODE -eq 0)
			ExitCode = $LASTEXITCODE
			Output   = ($output | Out-String).Trim()
		}
	}
	catch {
		[pscustomobject]@{
			Success  = $false
			ExitCode = $null
			Output   = $_.Exception.Message
		}
	}
}

<#
.SYNOPSIS
Applies a set of resolved mapping requests: maps each Share via net.exe and each Printer via Add-Printer.

.DESCRIPTION
For each entry, checks whether the mapping already exists and skips it if so - mappings are additive,
never re-applied or removed. Shares are checked via Get-SmbMapping -RemotePath. Printers are checked by
reconstructing "\\<ComputerName>\<ShareName>" from each installed Get-Printer entry and comparing that to
the requested connection path - not Get-Printer -Name, since Windows names an installed network-printer
connection after the driver's friendly name (e.g. "\\server\Canon Inkjet MX340 series"), not the literal
UNC path it was connected with, so a -Name match against the connection path never finds an existing
mapping. Otherwise maps it: shares via Invoke-NetUseCommand, warning (not throwing) on failure; printers via
`Add-Printer -ConnectionName -ErrorAction Stop`, wrapped in try/catch and warning on failure - the
-ErrorAction Stop is required because Add-Printer's CIM-backed errors are non-terminating by default, so
without it a failed Add-Printer call would fall through to the success log line uncaught.

.PARAMETER ObjectsToMap
Hashtable keyed by "Type|Path" whose values are mapping request objects (Type/Path/MountPoint), typically
built from the output of Resolve-ShareMountPointAssignment.

.OUTPUTS
A single summary object with Requested/Mapped/AlreadyPresent/Failed counts. Requested is simply the input
count; the other three are tallied from what each request actually did, so a run that is handed three
requests and fails one reports Mapped 2, not Mapped 3.

.EXAMPLE
Add-ObjectMapping -ObjectsToMap $ObjectToMap
#>
function Add-ObjectMapping {
	[CmdletBinding()]
	param(
		$ObjectsToMap
	)
	Write-Verbose $MyInvocation.MyCommand
	$Mapped = 0
	$AlreadyPresent = 0
	$Failed = 0
	foreach ($Key in $ObjectsToMap.Keys) {
		Write-Verbose ('Processing: ' + $Key)
		switch ($ObjectsToMap.Item($Key).Type) {

			'Share' {
				Write-Verbose ('The type of key ' + $Key + ' is Share')
				if (!(Get-SmbMapping -RemotePath $ObjectsToMap.Item($Key).Path -ErrorAction SilentlyContinue)) {
					Write-Verbose ('No mapping to ' + $ObjectsToMap.Item($Key).Path + ' found.')
					Write-Verbose ('Map share: ' + $ObjectsToMap.Item($Key).Path)
					$result = Invoke-NetUseCommand -MountPoint $ObjectsToMap.Item($Key).MountPoint -Path $ObjectsToMap.Item($Key).Path
					if ($result.Success) {
						$Mapped++
						Write-Verbose ('Successfully mapped share: ' + $ObjectsToMap.Item($Key).Path)
					}
					else {
						$Failed++
						Write-Warning ('Could not map share: ' + $ObjectsToMap.Item($Key).Path + ' (net.exe exit code ' + $result.ExitCode + '): ' + $result.Output)
					}
				}
				else {
					$AlreadyPresent++
					Write-Verbose ('Mapping to ' + $ObjectsToMap.Item($Key).Path + ' already exists.')
				}
			}
			'Printer' {
				Write-Verbose ('The type of key ' + $Key + ' is Printer')
				$existingPrinter = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
					$_.ComputerName -and $_.ShareName -and "\\$($_.ComputerName)\$($_.ShareName)" -eq $ObjectsToMap.Item($Key).Path
				}
				if (-not $existingPrinter) {
					Write-Verbose ('No mapping to ' + $ObjectsToMap.Item($Key).Path + ' found.')
					try {
						Write-Verbose ('Map printer: ' + $ObjectsToMap.Item($Key).Path)
						Add-Printer -ConnectionName $ObjectsToMap.Item($Key).Path -ErrorAction Stop | Out-Null
						$Mapped++
						Write-Verbose ('Successfully mapped printer: ' + $ObjectsToMap.Item($Key).Path)
					}
					catch {
						$Failed++
						Write-Warning ('Could not map printer: ' + $ObjectsToMap.Item($Key).Path + ' Error message: ' + $_.Exception.Message)
					}
				}
				else {
					$AlreadyPresent++
					Write-Verbose ('Mapping to ' + $ObjectsToMap.Item($Key).Path + ' already exists.')
				}
			}
		}
	}
	[pscustomobject]@{
		Requested      = $ObjectsToMap.Count
		Mapped         = $Mapped
		AlreadyPresent = $AlreadyPresent
		Failed         = $Failed
	}
}
<#
.SYNOPSIS
Runs the full drive/printer mapping workflow for the currently signed-in user: log rotation, AD
reachability pre-flight, UPN/user/group resolution, mapping request assembly, and applying the mappings.

.DESCRIPTION
Orchestrates every function above into the end-to-end flow described in the script-level help. Not
unit-tested directly (see the script-level .NOTES) - it requires a real, domain-joined-or-equivalent
Windows environment with LDAP connectivity, and is instead validated by running it live plus the
Pester-covered pure/boundary-mocked functions it calls. Uses the script's top-level $ADGroupPrefix,
$GroupMappingProperty, $HomeShareMappingProperty, $HomeShareMappingMountPoint, $ADDelimiter, $ADDomain,
$ADPort, and $LogfilePath parameters - takes no parameters of its own.

Exits 0 quietly if AD is unreachable (Test-ADReachable). Throws (after stopping the transcript) if no UPN
can be resolved. Exits -1 (after stopping the transcript) if the AD user search doesn't find exactly one
match. Otherwise resolves mapping requests, assigns mount points, applies them via Add-ObjectMapping, and
stops the transcript.

.EXAMPLE
Invoke-MapDrivesAndPrinter
#>
function Invoke-MapDrivesAndPrinter {
	[CmdletBinding()]
	param()

$VerbosePreference = 'Continue'
Invoke-LogRotation -filePath $LogfilePath -fileRetentionCount 3 -suffix 'old'
Start-Transcript -Path $LogfilePath -Force

if (-not (Test-ADReachable -ADDomain $ADDomain -Port $ADPort)) {
	Write-Verbose "Active Directory ($ADDomain) is not reachable on $($ADPort -join ', '); exiting quietly."
	Stop-Transcript
	exit 0
}

$UserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
Write-Verbose (' User SID: ' + $UserSid.Value.ToString())
$UserUPN = Resolve-UserPrincipalName -Sid $UserSid.Value
if (-not $UserUPN) {
    Write-Verbose -Message "UserUPN not found."
    Stop-Transcript
    Throw "UserUPN not found."
}

Write-Verbose (' User UPN: ' + $UserUPN)
$UserObject = Get-ADSIObject -LDAPFilter "(&(objectCategory=user)(userPrincipalName=$($UserUPN)))" -SearchRoot ([ADSI] "LDAP://$($ADDomain)")
Write-Verbose (' User Object Count (should be 1): ' + $UserObject.Count)

if ($UserObject.Count -ne 1) {
	Write-Error -Message "AD Search found $($UserObject.Count) objects. Search did either find none or more than 1 item."
	Stop-Transcript
	exit -1
}

$ADGroup = @{}
foreach ($MappingType in $ADGroupPrefix.Keys) {
	Write-Verbose ('Processing Mapping Type: ' + $MappingType)
	if ($ADGroupPrefix.Item($MappingType) -ne '') {
		$Null = [array]($ADGroup.Item($MappingType)) += Get-MemberOfMappings -MemberOf $UserObject.Properties.memberof -SearchPattern $ADGroupPrefix.Item($MappingType) -recurse $true
	}
}

$MappingRequests = @(Resolve-ObjectsToMap -UserObject $UserObject -ADGroup $ADGroup -GroupMappingProperty $GroupMappingProperty -ADDelimiter $ADDelimiter -HomeShareMappingProperty $HomeShareMappingProperty -HomeShareMappingMountPoint $HomeShareMappingMountPoint)
$AssignedMappings = Resolve-ShareMountPointAssignment -Requests $MappingRequests -InUseMountPoints (Get-InUseMountPoint)

$ObjectToMap = @{}
foreach ($item in $AssignedMappings) {
	$ObjectToMap["$($item.Type)|$($item.Path)"] = $item
}

$MappingSummary = Add-ObjectMapping -ObjectsToMap $ObjectToMap
Write-Verbose ('Finished processing. Requested ' + $MappingSummary.Requested + ', mapped ' + $MappingSummary.Mapped + ', already present ' + $MappingSummary.AlreadyPresent + ', failed ' + $MappingSummary.Failed + '.')
Stop-Transcript
}

if ($MyInvocation.InvocationName -ne '.') {
	Invoke-MapDrivesAndPrinter
}