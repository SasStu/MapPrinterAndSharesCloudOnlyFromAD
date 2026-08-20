# MapPrinterAndSharesCloudOnlyFromAD

Maps network drives and printers for the signed-in user on **Entra-joined (cloud-only) Windows devices**,
driven by the user's **on-prem Active Directory group memberships**.

No domain join, no `ActiveDirectory` module, no stored credentials, no Group Policy. The script binds to
LDAP via raw ADSI as the signed-in user, reads mapping data from AD attributes, and applies the mappings
with `net.exe use` and `Add-Printer`.

> **Companion article:** [Part 1 - Using Active Directory Information on Cloud-Only Devices to Map Printers and Shares](https://sastu-insights.com/posts/Part-1-Using-Active-Directory-Information-on-Cloud-Only-Devices-to-Map-Printers-and-Shares/)
> walks through the reasoning behind this approach - why the usual options fall short on Entra-joined
> devices, and what the prerequisites actually cost you.

## How it works

1. **Log rotation + transcript** - rotates the per-user log (3 generations) and starts a transcript.
2. **AD reachability pre-flight** - TCP probe against the domain on 389, then 636. If nothing answers,
   the script exits `0` quietly instead of hanging or failing (roaming laptops off the corporate network).
3. **Resolve the user's UPN** - from local registry caches, in order:
   - `HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\<Sid>\IdentityCache\<Sid>\UserName`
   - `HKCU:\...\WorkplaceJoin\AADNGC` (only when exactly one valid candidate exists)
   - `whoami /upn` as a last resort only - spawning `whoami.exe` from a scheduled task is a pattern
     endpoint protection tends to flag as reconnaissance.

   Every candidate is validated against the current Windows identity: the local part before `@` must
   equal the current SamAccountName, so a stale or cross-account cache entry is discarded.
4. **Look up the AD user object** by `userPrincipalName`. Exits `-1` unless exactly one object matches.
5. **Walk group memberships** - recursively resolves `memberOf` (including nested groups), keeping the
   groups whose **CN starts with** a configured prefix. A visited-set guards against membership cycles
   and re-processing diamond memberships.
6. **Build mapping requests** - each matched group's mapping attribute is parsed as
   `<UNC path><delimiter><mount point>`, plus an optional home share from a user-level attribute.
   Requests are deduplicated by `Type|Path`.
7. **Assign drive letters** - starting from the requested letter and cycling forward through the alphabet,
   skipping letters already in use on the device (any filesystem drive, not just SMB mappings) and letters
   already claimed earlier in the same run.
8. **Apply the mappings** - shares via `net.exe use <letter>: <path> /persistent:Yes`, printers via
   `Add-Printer -ConnectionName`. Existing mappings are skipped.

**Mappings are additive - nothing is ever removed by this script.** Malformed group data, an unmappable
share, or a failing printer connection produces a warning and is skipped; the rest of the run continues.

## Repository layout

```text
Script/MapDrivesAndPrinter.ps1          The whole thing - orchestrator plus all functions
Install/SMBShares.xml                   Importable scheduled task definition
Tests/MapDrivesAndPrinter.Tests.ps1     Pester 5 unit tests
```

## Requirements

- Windows with PowerShell 5.1 or later
- Entra-joined device with network line-of-sight to a domain controller (VPN, LAN, SASE)
- The signed-in user must be able to authenticate to on-prem AD so the LDAP bind succeeds with no stored
  credentials. This is free for hybrid users signing in with username and password; **passwordless
  sign-in (Windows Hello for Business, FIDO2) needs Cloud Kerberos Trust** or an equivalent trust model.
- An Intune NetworkListManager CSP profile granting the **Domain firewall profile** on network connect -
  otherwise the device treats the corporate network as Public and blocks the traffic.

## AD data model

Create one AD group per share and per printer, named with the configured prefix, and put the mapping value
in the configured attribute (`info` by default):

| Group CN             | `info` value        | Result                          |
| -------------------- | ------------------- | ------------------------------- |
| `RIG-MEM-FS-Finance` | `\\fs01\finance;F`  | `\\fs01\finance` mapped to `F:` |
| `RIG-PRT-Reception`  | `\\prt01\Reception` | Printer connection added        |

For printers the mount-point segment is ignored and may be omitted. The home share is read from a
user-level attribute (`extensionattribute3` by default) and mapped to `H:`.

Users get their mappings by being a member of the group - directly or through nesting.

## Usage

Run the full workflow for the signed-in user:

```powershell
.\Script\MapDrivesAndPrinter.ps1
```

Dot-source it to load the functions **without** running anything (interactive testing, Pester):

```powershell
. .\Script\MapDrivesAndPrinter.ps1
```

Override the defaults:

```powershell
.\Script\MapDrivesAndPrinter.ps1 `
    -ADDomain 'contoso.com' `
    -ADGroupPrefix @{ Printer = 'PRT-'; Share = 'FS-' } `
    -GroupMappingProperty 'info' `
    -ADDelimiter ';'
```

### Parameters

| Parameter                    | Default                                             | Purpose                                                             |
| ---------------------------- | --------------------------------------------------- | ------------------------------------------------------------------- |
| `ADGroupPrefix`              | `@{ Printer = 'RIG-PRT-'; Share = 'RIG-MEM-FS-' }`  | CN prefix per mapping type. Set a type to `''` to skip it entirely. |
| `GroupMappingProperty`       | `info`                                              | Group attribute holding `<UNC path><delimiter><mount point>`.       |
| `HomeShareMappingProperty`   | `extensionattribute3`                               | User attribute holding the home share UNC path. Empty to skip.      |
| `HomeShareMappingMountPoint` | `H`                                                 | Drive letter requested for the home share.                          |
| `ADDelimiter`                | `;`                                                 | Separator between path and mount point.                             |
| `ADDomain`                   | `contoso.com`                                       | DNS domain to bind against. **Change this for your environment.**   |
| `ADPort`                     | `389, 636`                                          | Ports tried by the reachability probe, in order.                    |
| `LogfilePath`                | `%LOCALAPPDATA%\MapPrinterAndShares\MapFromMWP.log` | Per-user transcript, rotated to `.old1`-`.old3`.                    |

## Deployment

Deploy as a **scheduled task running in the user context**, triggered at logon and on network connect.
[`Install/SMBShares.xml`](Install/SMBShares.xml) is a ready-made task definition:

```powershell
Register-ScheduledTask -TaskName 'MapDrivesAndPrinter' -Xml (Get-Content .\Install\SMBShares.xml -Raw)
```

It expects the script at `C:\Program Files\MapDrivesAndPrinter\MapDrivesAndPrinter.ps1` - copy it there
first, or edit the `<Arguments>` element to match your own path.

What the definition does, and why:

- **Principal `S-1-5-32-545` (Builtin\Users) at `LeastPrivilege`** - the task runs as whoever is signed
  in, not elevated, so the LDAP bind uses the user's own identity.
- **Logon trigger** - covers the normal case.
- **Event trigger on Firewall event `2010` with `NewProfile = 1`, delayed `PT1M`** - fires when the
  connection is classified into the **Domain** profile, i.e. the moment the device actually gains line of
  sight to the corporate network. This is what makes VPN and docking-station scenarios work.
- **`MultipleInstancesPolicy = IgnoreNew`** so overlapping triggers can't stack up.
- **`ExecutionTimeLimit = PT1H`** as a backstop, and `Hidden = true` so no console window flashes
  (the action runs `conhost.exe --headless` around `powershell.exe`).

The script's own reachability pre-flight and LDAP client timeout mean an off-network run costs a few
seconds and exits cleanly, so triggering it often is cheap.

## Tests

[`Tests/MapDrivesAndPrinter.Tests.ps1`](Tests/MapDrivesAndPrinter.Tests.ps1) covers the pure logic -
mount point selection, group description parsing, `memberOf` walking, mapping resolution, UPN resolution
and the mapping summary - with Pester 5. The tests dot-source the script, so nothing is mapped and no AD
is contacted.

```powershell
Invoke-Pester .\Tests\MapDrivesAndPrinter.Tests.ps1
```

## Exit behaviour

| Condition                 | Behaviour                                              |
| ------------------------- | ------------------------------------------------------ |
| AD unreachable            | Exit `0` quietly - expected off-network                |
| No UPN resolvable         | Throws                                                 |
| AD user search != 1 match | `Write-Error` and exit `-1`                            |
| Group data malformed      | Warning, that group is skipped, run continues          |
| A single mapping fails    | Warning, counted as `Failed` in the summary, continues |

Each run ends with a summary line: requested / mapped / already present / failed.

## Troubleshooting

Read the transcript at `%LOCALAPPDATA%\MapPrinterAndShares\MapFromMWP.log` (previous runs in `.old1` -
`.old3`). The script runs with `$VerbosePreference = 'Continue'`, so the log contains the full decision
trail: which UPN source won, which groups matched, which letters were assigned, and what `net.exe`
returned verbatim.

Common causes:

- **Exits immediately, "not reachable"** - no line of sight to a DC, or the connection is classified as a
  Public network rather than Domain.
- **"No registry-cached UPN matched the current user"** - the cache is stale or belongs to another
  account; the run falls back to `whoami /upn`.
- **AD search found 0 objects** - the resolved UPN has no matching on-prem user (cloud-only account).
- **Share fails to map** - the log carries `net.exe`'s exit code and its own message; typically an
  authentication failure, which points back to the Kerberos trust prerequisite.

## Further reading

- [Part 1 - Using Active Directory Information on Cloud-Only Devices to Map Printers and Shares](https://sastu-insights.com/posts/Part-1-Using-Active-Directory-Information-on-Cloud-Only-Devices-to-Map-Printers-and-Shares/)
  - the write-up this repository accompanies.
