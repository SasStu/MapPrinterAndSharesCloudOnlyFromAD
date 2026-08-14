#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
	. "$PSScriptRoot/../Script/MapDrivesAndPrinter.ps1"
}

Describe 'Get-AvailableMountPoint' {
	It 'returns the requested mount point when it is not in use' {
		Get-AvailableMountPoint -Requested 'H' -UnavailableMountPoints @() | Should -Be 'H'
	}

	It 'returns the next free letter when the requested one is in use' {
		Get-AvailableMountPoint -Requested 'H' -UnavailableMountPoints @('H') | Should -Be 'I'
	}

	It 'wraps from Z back to A when the requested letter and everything after it is in use' {
		Get-AvailableMountPoint -Requested 'Y' -UnavailableMountPoints @('Y', 'Z') | Should -Be 'A'
	}

	It 'returns null when every mount point is in use' {
		$allLetters = 65..90 | ForEach-Object { [string][char]$_ }
		Get-AvailableMountPoint -Requested 'C' -UnavailableMountPoints $allLetters | Should -BeNullOrEmpty
	}

	It 'treats requested and unavailable mount points case-insensitively' {
		Get-AvailableMountPoint -Requested 'h' -UnavailableMountPoints @('H') | Should -Be 'I'
	}
}

Describe 'Resolve-MappingGroupDescription' {
	It 'accepts a well-formed share description' {
		$result = Resolve-MappingGroupDescription -Type 'Share' -Description '\\fs01\finance;F'
		$result.IsValid | Should -BeTrue
		$result.Path | Should -Be '\\fs01\finance'
		$result.MountPoint | Should -Be 'F'
	}

	It 'accepts a printer description with no mount point segment, forcing MountPoint empty' {
		$result = Resolve-MappingGroupDescription -Type 'Printer' -Description '\\print01\Finance-MFP'
		$result.IsValid | Should -BeTrue
		$result.Path | Should -Be '\\print01\Finance-MFP'
		$result.MountPoint | Should -BeNullOrEmpty
	}

	It 'rejects a share description missing its mount point' {
		$result = Resolve-MappingGroupDescription -Type 'Share' -Description '\\fs01\finance'
		$result.IsValid | Should -BeFalse
		$result.ValidationError | Should -Not -BeNullOrEmpty
	}

	It 'rejects a share description whose mount point is not a single letter' {
		$result = Resolve-MappingGroupDescription -Type 'Share' -Description '\\fs01\finance;FIN'
		$result.IsValid | Should -BeFalse
	}

	It 'rejects a description whose path is not UNC-shaped' {
		$result = Resolve-MappingGroupDescription -Type 'Share' -Description 'C:\local\finance;F'
		$result.IsValid | Should -BeFalse
	}
}

Describe 'Get-MemberOfMappings' {
	BeforeEach {
		$script:testGroups = @{}
		Mock Get-ADSIObject {
			if ($LDAPFilter -match 'distinguishedName=(?<dn>[^)]+)\)') {
				$dn = $Matches.dn
				if ($script:testGroups.ContainsKey($dn)) {
					return @($script:testGroups[$dn])
				}
			}
			return @()
		}
	}

	It 'returns the group when its CN starts with the search pattern' {
		$script:testGroups['CN=RIG-SMB-Finance,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('RIG-SMB-Finance'); memberof = @() }
		}

		$result = @(Get-MemberOfMappings -MemberOf @('CN=RIG-SMB-Finance,OU=Groups,DC=domain,DC=int') -SearchPattern 'RIG-SMB-' -recurse $true)

		$result.Count | Should -Be 1
	}

	It 'does not match a group whose OU contains the pattern but whose CN does not start with it' {
		$script:testGroups['CN=Finance,OU=RIG-SMB-Legacy,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('Finance'); memberof = @() }
		}

		$result = @(Get-MemberOfMappings -MemberOf @('CN=Finance,OU=RIG-SMB-Legacy,DC=domain,DC=int') -SearchPattern 'RIG-SMB-' -recurse $true)

		$result.Count | Should -Be 0
	}

	It 'does not process the same group twice when reached through two nested paths' {
		$script:testGroups['CN=X,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('X'); memberof = @('CN=RIG-SMB-Shared,OU=Groups,DC=domain,DC=int') }
		}
		$script:testGroups['CN=Y,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('Y'); memberof = @('CN=RIG-SMB-Shared,OU=Groups,DC=domain,DC=int') }
		}
		$script:testGroups['CN=RIG-SMB-Shared,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('RIG-SMB-Shared'); memberof = @() }
		}

		$result = @(Get-MemberOfMappings -MemberOf @('CN=X,OU=Groups,DC=domain,DC=int', 'CN=Y,OU=Groups,DC=domain,DC=int') -SearchPattern 'RIG-SMB-' -recurse $true)

		$result.Count | Should -Be 1
	}

	It 'does not infinite-loop when group membership forms a cycle' {
		$script:testGroups['CN=A,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('A'); memberof = @('CN=B,OU=Groups,DC=domain,DC=int') }
		}
		$script:testGroups['CN=B,OU=Groups,DC=domain,DC=int'] = [pscustomobject]@{
			Properties = @{ cn = @('B'); memberof = @('CN=A,OU=Groups,DC=domain,DC=int') }
		}

		$result = @(Get-MemberOfMappings -MemberOf @('CN=A,OU=Groups,DC=domain,DC=int') -SearchPattern 'RIG-SMB-' -recurse $true)

		$result.Count | Should -Be 0
	}
}

Describe 'Resolve-ObjectsToMap' {
	It 'includes a valid AD group as a mapping request' {
		$adGroup = @{
			Share = @(
				[pscustomobject]@{ Properties = @{ cn = @('RIG-SMB-Finance'); description = @('\\fs01\finance;F') } }
			)
		}
		$userObject = [pscustomobject]@{ Properties = @{} }

		$result = @(Resolve-ObjectsToMap -UserObject $userObject -ADGroup $adGroup -GroupMappingProperty 'description' -ADDelimiter ';')

		$result.Count | Should -Be 1
		$result[0].Type | Should -Be 'Share'
		$result[0].Path | Should -Be '\\fs01\finance'
		$result[0].MountPoint | Should -Be 'F'
	}

	It 'skips a group with a malformed description and does not throw' {
		$adGroup = @{
			Share = @(
				[pscustomobject]@{ Properties = @{ cn = @('RIG-SMB-Broken'); description = @('not-a-unc-path') } }
			)
		}
		$userObject = [pscustomobject]@{ Properties = @{} }

		$result = @(Resolve-ObjectsToMap -UserObject $userObject -ADGroup $adGroup -GroupMappingProperty 'description' -ADDelimiter ';' -WarningAction SilentlyContinue)

		$result.Count | Should -Be 0
	}

	It 'deduplicates two groups that resolve to the same Type and Path' {
		$adGroup = @{
			Printer = @(
				[pscustomobject]@{ Properties = @{ cn = @('RIG-PRT-FinanceA'); description = @('\\print01\Finance-MFP') } }
				[pscustomobject]@{ Properties = @{ cn = @('RIG-PRT-FinanceB'); description = @('\\print01\Finance-MFP') } }
			)
		}
		$userObject = [pscustomobject]@{ Properties = @{} }

		$result = @(Resolve-ObjectsToMap -UserObject $userObject -ADGroup $adGroup -GroupMappingProperty 'description' -ADDelimiter ';')

		$result.Count | Should -Be 1
	}

	It 'includes a well-formed home share as a Share request' {
		$adGroup = @{}
		$userObject = [pscustomobject]@{ Properties = @{ extensionattribute3 = '\\fs01\home\jdoe' } }

		$result = @(Resolve-ObjectsToMap -UserObject $userObject -ADGroup $adGroup -HomeShareMappingProperty 'extensionattribute3' -HomeShareMappingMountPoint 'H')

		$result.Count | Should -Be 1
		$result[0].Type | Should -Be 'Share'
		$result[0].Path | Should -Be '\\fs01\home\jdoe'
		$result[0].MountPoint | Should -Be 'H'
	}

	It 'skips a home share value that is not UNC-shaped' {
		$adGroup = @{}
		$userObject = [pscustomobject]@{ Properties = @{ extensionattribute3 = 'not-a-unc-path' } }

		$result = @(Resolve-ObjectsToMap -UserObject $userObject -ADGroup $adGroup -HomeShareMappingProperty 'extensionattribute3' -HomeShareMappingMountPoint 'H' -WarningAction SilentlyContinue)

		$result.Count | Should -Be 0
	}
}

Describe 'Resolve-ShareMountPointAssignment' {
	It 'assigns the requested mount point when it is free' {
		$requests = @([pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' })

		$result = @(Resolve-ShareMountPointAssignment -Requests $requests -InUseMountPoints @())

		$result[0].MountPoint | Should -Be 'F'
	}

	It 'assigns the next free letter when the requested one is already in use on the device' {
		$requests = @([pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'H' })

		$result = @(Resolve-ShareMountPointAssignment -Requests $requests -InUseMountPoints @('H'))

		$result[0].MountPoint | Should -Be 'I'
	}

	It 'drops a share and warns when no mount point is available' {
		$allLetters = 65..90 | ForEach-Object { [string][char]$_ }
		$requests = @([pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' })

		$result = @(Resolve-ShareMountPointAssignment -Requests $requests -InUseMountPoints $allLetters -WarningAction SilentlyContinue)

		$result.Count | Should -Be 0
	}

	It 'passes printer requests through unchanged' {
		$requests = @([pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Finance-MFP'; MountPoint = '' })

		$result = @(Resolve-ShareMountPointAssignment -Requests $requests -InUseMountPoints @('F', 'G'))

		$result.Count | Should -Be 1
		$result[0].Path | Should -Be '\\print01\Finance-MFP'
	}

	It 'does not let two share requests in the same run claim the same letter' {
		$requests = @(
			[pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' }
			[pscustomobject]@{ Type = 'Share'; Path = '\\fs01\legal'; MountPoint = 'F' }
		)

		$result = @(Resolve-ShareMountPointAssignment -Requests $requests -InUseMountPoints @())

		($result | Select-Object -ExpandProperty MountPoint | Sort-Object -Unique).Count | Should -Be 2
	}

	It 'accepts an empty request list without throwing and returns nothing' {
		$result = @(Resolve-ShareMountPointAssignment -Requests @() -InUseMountPoints @())

		$result.Count | Should -Be 0
	}
}

Describe 'Add-ObjectMapping (Share)' {
	BeforeEach {
		Mock Invoke-NetUseCommand { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
	}

	It 'does not attempt to map a share that Get-SmbMapping already reports as mapped' {
		Mock Get-SmbMapping { [pscustomobject]@{ RemotePath = '\\fs01\finance' } }

		Add-ObjectMapping -ObjectsToMap @{ 'Share|\\fs01\finance' = [pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' } }

		Should -Invoke Invoke-NetUseCommand -Times 0
	}

	It 'maps a share that is not yet present by calling Invoke-NetUseCommand with the resolved mount point and path' {
		Mock Get-SmbMapping { $null }

		Add-ObjectMapping -ObjectsToMap @{ 'Share|\\fs01\finance' = [pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' } }

		Should -Invoke Invoke-NetUseCommand -Times 1 -ParameterFilter { $MountPoint -eq 'F' -and $Path -eq '\\fs01\finance' }
	}

	It 'logs a warning and does not throw when net.exe reports failure' {
		Mock Get-SmbMapping { $null }
		Mock Invoke-NetUseCommand { [pscustomobject]@{ Success = $false; ExitCode = 67; Output = 'System error 67 has occurred.' } }

		Add-ObjectMapping -ObjectsToMap @{ 'Share|\\fs01\finance' = [pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' } } -WarningAction SilentlyContinue -WarningVariable warnings
		$warnings.Count | Should -BeGreaterThan 0
	}
}

Describe 'Add-ObjectMapping (Printer)' {
	It 'does not attempt to map a printer whose ComputerName/ShareName reconstruct the requested connection path' {
		# Get-Printer's Name is the driver's friendly name (e.g. "\\print01\HP LaserJet Pro"), not the
		# literal connection path it was added with - the existence check must reconstruct the path from
		# ComputerName/ShareName rather than matching on Name.
		Mock Get-Printer { [pscustomobject]@{ Name = '\\print01\HP LaserJet Pro'; ComputerName = 'print01'; ShareName = 'Finance-MFP' } }
		Mock Add-Printer { }

		Add-ObjectMapping -ObjectsToMap @{ 'Printer|\\print01\Finance-MFP' = [pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Finance-MFP'; MountPoint = '' } }

		Should -Invoke Add-Printer -Times 0
	}

	It 'maps a printer that is not yet present by calling Add-Printer with the resolved connection name' {
		Mock Get-Printer { $null }
		Mock Add-Printer { }

		Add-ObjectMapping -ObjectsToMap @{ 'Printer|\\print01\Finance-MFP' = [pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Finance-MFP'; MountPoint = '' } }

		Should -Invoke Add-Printer -Times 1 -ParameterFilter { $ConnectionName -eq '\\print01\Finance-MFP' }
	}

	It 'logs a warning and does not throw when Add-Printer reports failure via a non-terminating CIM error' {
		Mock Get-Printer { $null }
		Mock Add-Printer { Write-Error -Message 'The specified server does not exist, or the server or printer name is invalid.' }

		Add-ObjectMapping -ObjectsToMap @{ 'Printer|\\print01\Finance-MFP' = [pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Finance-MFP'; MountPoint = '' } } -WarningAction SilentlyContinue -WarningVariable warnings
		$warnings.Count | Should -BeGreaterThan 0
	}
}

Describe 'Add-ObjectMapping (summary)' {
	It 'counts only what actually mapped, not what was requested' {
		# Regression: the run summary used to report the number of requests handed in, so a run that was
		# given three requests and failed one still claimed it had mapped three.
		Mock Get-SmbMapping { $null }
		Mock Invoke-NetUseCommand { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
		Mock Get-Printer { $null }
		Mock Add-Printer {
			if ($ConnectionName -eq '\\print01\Missing') { throw 'The specified server does not exist.' }
		}

		$summary = Add-ObjectMapping -ObjectsToMap @{
			'Share|\\fs01\finance'      = [pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' }
			'Printer|\\print01\Good'    = [pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Good'; MountPoint = '' }
			'Printer|\\print01\Missing' = [pscustomobject]@{ Type = 'Printer'; Path = '\\print01\Missing'; MountPoint = '' }
		} -WarningAction SilentlyContinue

		$summary.Requested | Should -Be 3
		$summary.Mapped | Should -Be 2
		$summary.Failed | Should -Be 1
		$summary.AlreadyPresent | Should -Be 0
	}

	It 'counts an existing mapping as already present rather than as newly mapped' {
		Mock Get-SmbMapping { [pscustomobject]@{ RemotePath = '\\fs01\finance' } }
		Mock Invoke-NetUseCommand { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }

		$summary = Add-ObjectMapping -ObjectsToMap @{
			'Share|\\fs01\finance' = [pscustomobject]@{ Type = 'Share'; Path = '\\fs01\finance'; MountPoint = 'F' }
		}

		$summary.Requested | Should -Be 1
		$summary.Mapped | Should -Be 0
		$summary.AlreadyPresent | Should -Be 1
		$summary.Failed | Should -Be 0
	}
}

Describe 'Resolve-UserPrincipalName' {
	BeforeEach {
		Mock Get-CurrentSamAccountName { 'jdoe' }
		Mock Invoke-WhoamiUpnCommand { $null }
	}

	It 'returns the UPN from the IdentityStore cache when present, valid, and matching the current user' {
		Mock Test-Path { $true } -ParameterFilter { $Path -like '*IdentityStore*' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserName = 'jdoe@contoso.com' } } -ParameterFilter { $Path -like '*IdentityStore*' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' | Should -Be 'jdoe@contoso.com'
		Should -Invoke Invoke-WhoamiUpnCommand -Times 0
	}

	It 'falls back to AADNGC when the IdentityStore entry is absent' {
		Mock Test-Path { $false } -ParameterFilter { $Path -like '*IdentityStore*' }
		Mock Test-Path { $true } -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ChildItem { @([pscustomobject]@{ PSPath = 'AADNGC-SubKey-1' }) } -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserId = 'jdoe@contoso.com' } } -ParameterFilter { $Path -eq 'AADNGC-SubKey-1' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' | Should -Be 'jdoe@contoso.com'
	}

	It 'returns null and warns when AADNGC has multiple valid UPN candidates, and does not fall back to whoami' {
		Mock Test-Path { $false } -ParameterFilter { $Path -like '*IdentityStore*' }
		Mock Test-Path { $true } -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ChildItem {
			@(
				[pscustomobject]@{ PSPath = 'AADNGC-SubKey-1' }
				[pscustomobject]@{ PSPath = 'AADNGC-SubKey-2' }
			)
		} -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserId = 'jdoe@contoso.com' } } -ParameterFilter { $Path -eq 'AADNGC-SubKey-1' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserId = 'asmith@contoso.com' } } -ParameterFilter { $Path -eq 'AADNGC-SubKey-2' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
	}

	It 'returns null when neither source has a usable UPN and whoami also yields nothing' {
		Mock Test-Path { $false }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
	}

	It 'ignores an IdentityStore UPN that does not match the current user and falls back to AADNGC' {
		Mock Test-Path { $true } -ParameterFilter { $Path -like '*IdentityStore*' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserName = 'someoneelse@contoso.com' } } -ParameterFilter { $Path -like '*IdentityStore*' }
		Mock Test-Path { $true } -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ChildItem { @([pscustomobject]@{ PSPath = 'AADNGC-SubKey-1' }) } -ParameterFilter { $Path -like '*AADNGC*' }
		Mock Get-ItemProperty { [pscustomobject]@{ UserId = 'jdoe@contoso.com' } } -ParameterFilter { $Path -eq 'AADNGC-SubKey-1' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' -WarningAction SilentlyContinue | Should -Be 'jdoe@contoso.com'
	}

	It 'falls back to whoami /upn as a last resort when no registry source matches the current user' {
		Mock Test-Path { $false }
		Mock Invoke-WhoamiUpnCommand { 'jdoe@contoso.com' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' -WarningAction SilentlyContinue | Should -Be 'jdoe@contoso.com'
		Should -Invoke Invoke-WhoamiUpnCommand -Times 1
	}

	It 'returns null when the whoami /upn fallback output is not UPN-shaped' {
		Mock Test-Path { $false }
		Mock Invoke-WhoamiUpnCommand { 'not-a-upn' }

		Resolve-UserPrincipalName -Sid 'S-1-5-21-1-2-3-1001' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
	}
}

Describe 'Get-InUseMountPoint' {
	It 'returns the letters of drives currently present on the device, uppercased' {
		Mock Get-PSDrive {
			@(
				[pscustomobject]@{ Name = 'C' }
				[pscustomobject]@{ Name = 'h' }
			)
		} -ParameterFilter { $PSProvider -eq 'FileSystem' }

		Get-InUseMountPoint | Should -Be @('C', 'H')
	}
}
