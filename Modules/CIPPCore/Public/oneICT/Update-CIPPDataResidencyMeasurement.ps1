function Update-CIPPDataResidencyMeasurement {
    <#
    .SYNOPSIS
        Measures the 'Datenresidenz Schweiz' factory default for tenants and stores it (oneICT customisation, Item 230).
    .DESCRIPTION
        Reads the two Message Center posts per tenant in one Graph $batch per tenant, tenants concurrently
        (New-GraphMultiTenantBulkRequest, delegated GDAP token - ServiceMessage.Read.All is delegated only in the
        CIPP SAM app). Writes DefaultState/MessageCenterId/MeasuredAt into table oneICTDataResidency and leaves
        a technician's confirmation untouched. Returns one summary object per tenant.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tenants
    )

    $Posts = [ordered]@{ off = 'MC1470878'; on = 'MC1470876' }
    $TenantRequests = foreach ($Tenant in $Tenants) {
        @{
            TenantFilter = [string]$Tenant.defaultDomainName
            Requests     = @(foreach ($Key in $Posts.Keys) {
                    @{ id = $Key; method = 'GET'; url = "/admin/serviceAnnouncement/messages/$($Posts[$Key])?`$select=id,title,lastModifiedDateTime" }
                })
        }
    }
    $Sent = @(New-GraphMultiTenantBulkRequest -TenantRequests @($TenantRequests) -AsApp $false -Version 'v1.0')

    $Table = Get-CIPPTable -tablename 'oneICTDataResidency'
    $Now = (Get-Date).ToUniversalTime()
    $ByDomain = @{}
    foreach ($Tenant in $Tenants) { $ByDomain[[string]$Tenant.defaultDomainName] = $Tenant }

    foreach ($TenantResult in $Sent) {
        $Tenant = $ByDomain[[string]$TenantResult.TenantFilter]
        if (-not $Tenant) { continue }
        $Answered = @{}
        foreach ($Response in $TenantResult.Responses) { $Answered[[string]$Response.id] = $Response }

        $Found = @(foreach ($Key in $Posts.Keys) { if ([int]$Answered[$Key].status -eq 200) { $Key } })
        $Failed = @(foreach ($Key in $Posts.Keys) {
                $Status = [int]$Answered[$Key].status
                if (-not $Answered.ContainsKey($Key) -or ($Status -ne 200 -and $Status -ne 404)) { $Key }
            })

        $DefaultState, $MessageCenterId, $MeasureError = if ($TenantResult.Error) {
            'Error', '', ([string]$TenantResult.Error).Substring(0, [Math]::Min(500, ([string]$TenantResult.Error).Length))
        } elseif ($Found -contains 'off') {
            # A tenant that already switched the setting on still only has MC1470878; the confirmation decides.
            'Off', $Posts.off, ''
        } elseif ($Found -contains 'on') {
            'On', $Posts.on, ''
        } elseif ($Failed.Count -gt 0) {
            $First = $Answered[$Failed[0]]
            $Message = if ($First) { 'HTTP {0}: {1}' -f $First.status, ($First.body.error.message ?? '') } else { 'No response in the batch reply' }
            'Error', '', $Message
        } else {
            'None', '', ''
        }

        $Entity = @{
            PartitionKey      = 'Tenant'
            RowKey            = [string]$Tenant.customerId
            defaultDomainName = [string]$Tenant.defaultDomainName
            displayName       = [string]$Tenant.displayName
            DefaultState      = [string]$DefaultState
            MessageCenterId   = [string]$MessageCenterId
            MeasureError      = [string]$MeasureError
            MeasuredAt        = $Now
        }
        if ($PSCmdlet.ShouldProcess($Tenant.defaultDomainName, 'Store data residency measurement')) {
            # -OperationType UpsertMerge keeps ConfirmedState/ConfirmedBy/JITUser written by ExecDataResidency
            Add-CIPPAzDataTableEntity @Table -Entity $Entity -OperationType 'UpsertMerge'
        }
        [pscustomobject]$Entity
    }
}
