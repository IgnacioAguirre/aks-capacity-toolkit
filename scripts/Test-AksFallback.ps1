#requires -Version 7.2
<#
.SYNOPSIS
Exercise AKS fallback scheduling without modifying the Hello World Deployment.
.DESCRIPTION
Requires az, kubectl, authenticated Azure/Kubernetes access, completed README section 8,
and a non-production cluster with appfb at zero nodes. Reserves CPU to require at least
two fallback nodes, reports their SKUs, and pauses for inspection before cleanup.
Uses reserved CPU requests, not a CPU stress workload.
May create billable fallback nodes. Do not run concurrently with other cluster changes.
.EXAMPLE
.\scripts\Test-AksFallback.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ClusterName $Cluster -Context $Context -AllowNonProductionChanges
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup = $env:AKS_RESOURCE_GROUP,
    [string]$ClusterName = $env:AKS_CLUSTER_NAME,
    [string]$Context = $env:AKS_CONTEXT,
    [string]$Kubeconfig = $(if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $PSScriptRoot '..\.kube\config' }),
    [ValidateRange(1, 60)]
    [int]$TimeoutMinutes = 20,
    [string]$RecoveryPath,
    [switch]$SkipInspectionPause,
    [switch]$AllowNonProductionChanges
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Azure {
    param([string[]]$Arguments)
    $Output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
    return $Output
}

function Invoke-Kubernetes {
    param([string[]]$Arguments, [string]$InputJson)
    $Common = @('--kubeconfig', $Kubeconfig, '--context', $Context, '--request-timeout=30s')
    if ($InputJson) {
        $Output = $InputJson | & kubectl @Common @Arguments
    } else {
        $Output = & kubectl @Common @Arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "Kubernetes command failed: kubectl $($Arguments -join ' ')" }
    return $Output
}

function Read-Pool {
    param([string]$Name)
    $Json = Invoke-Azure -Arguments @('aks', 'nodepool', 'show', '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroup, '--cluster-name', $ClusterName, '--name', $Name, '-o', 'json')
    return ($Json | ConvertFrom-Json -AsHashtable)
}

function Wait-Cluster {
    Invoke-Azure -Arguments @('aks', 'wait', '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroup, '--name', $ClusterName,
        '--updated', '--interval', '15', '--timeout', '1800') | Out-Null
}

function Wait-PrimaryPool {
    Invoke-Azure -Arguments @('aks', 'nodepool', 'wait', '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroup, '--cluster-name', $ClusterName, '--name', 'appf8',
        '--updated', '--interval', '15', '--timeout', '1800') | Out-Null
    Wait-Cluster
}

function Set-PrimaryBounds {
    param([int]$Minimum, [int]$Maximum)
    Invoke-Azure -Arguments @('aks', 'nodepool', 'update', '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroup, '--cluster-name', $ClusterName, '--name', 'appf8',
        '--update-cluster-autoscaler', '--min-count', "$Minimum", '--max-count', "$Maximum",
        '--output', 'none') | Out-Null
    Wait-PrimaryPool
    $Actual = Read-Pool -Name 'appf8'
    if ($Actual.minCount -ne $Minimum -or $Actual.maxCount -ne $Maximum) {
        throw "Primary bounds verification failed; expected $Minimum-$Maximum"
    }
}

function Get-CpuMillis {
    param([string]$Quantity)
    if ($Quantity -match '^(?<value>[0-9]+)m$') { return [long]$Matches.value }
    if ($Quantity -match '^[0-9]+(\.[0-9]+)?$') {
        return [long]([decimal]::Parse($Quantity, [cultureinfo]::InvariantCulture) * 1000)
    }
    throw "Unsupported allocatable CPU quantity: '$Quantity'"
}

if (-not $AllowNonProductionChanges) {
    throw "This test changes autoscaler bounds and can provision billable nodes. Pass -AllowNonProductionChanges only for a non-production cluster."
}
foreach ($Value in @($SubscriptionId, $ResourceGroup, $ClusterName, $Context, $Kubeconfig)) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "SubscriptionId, ResourceGroup, ClusterName, Context, and Kubeconfig must all be set." }
}
if (-not (Test-Path -LiteralPath $Kubeconfig -PathType Leaf)) { throw "Kubeconfig file does not exist: $Kubeconfig" }
Get-Command az, kubectl -ErrorAction Stop | Out-Null

$ClusterJson = Invoke-Azure -Arguments @('aks', 'show', '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroup, '--name', $ClusterName, '-o', 'json')
$ClusterConfig = $ClusterJson | ConvertFrom-Json -AsHashtable
if ($ClusterConfig.provisioningState -ne 'Succeeded') { throw "Cluster has an active or failed operation; wait or resolve it before testing." }
if ($ClusterConfig.autoScalerProfile.expander -ne 'priority') { throw "Complete README step 8b: priority expansion is not enabled." }
$ConfigJson = Invoke-Kubernetes -Arguments @('config', 'view', '--minify', '-o', 'json')
$Config = $ConfigJson | ConvertFrom-Json -AsHashtable
$Server = [uri]$Config.clusters[0].cluster.server
if ($Server.Host -notin @($ClusterConfig.fqdn, $ClusterConfig.privateFqdn)) {
    throw "Kubernetes context does not target the Azure cluster's API hostname. Refusing to modify mismatched environments."
}
$PriorityJson = Invoke-Kubernetes -Arguments @('-n', 'kube-system', 'get', 'configmap', 'cluster-autoscaler-priority-expander', '-o', 'json')
$Priorities = ($PriorityJson | ConvertFrom-Json -AsHashtable).data.priorities
$Lines = @($Priorities -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (($Lines -join "`n") -cne "50:`n- .*appf8.*`n10:`n- .*appfb.*") {
    throw "Priority ConfigMap differs from README step 8c; review it before running this test."
}

$Primary = Read-Pool -Name 'appf8'
$Fallback = Read-Pool -Name 'appfb'
if ($Primary.provisioningState -ne 'Succeeded' -or -not $Primary.enableAutoScaling -or
    $null -eq $Primary.count -or $Primary.count -lt 1 -or
    $null -eq $Primary.minCount -or $null -eq $Primary.maxCount -or
    $Primary.minCount -gt $Primary.count -or $Primary.maxCount -lt $Primary.count) {
    throw "appf8 must be healthy with autoscaling enabled, valid bounds, and at least one existing node. Restore one baseline replica first if the pool is at zero."
}
$FallbackType = $Fallback.typePropertiesType
if (-not $FallbackType) { $FallbackType = $Fallback.type }
if ($Fallback.provisioningState -ne 'Succeeded' -or $FallbackType -ne 'VirtualMachines' -or
    $Fallback.mode -ne 'User' -or $Fallback.nodeLabels.workload -ne 'hello-world') {
    throw "appfb must be a healthy VirtualMachines User pool labeled workload=hello-world."
}
$Profiles = @($Fallback.virtualMachinesProfile.scale.autoscale)
if ($Profiles.Count -ne 2 -or @($Fallback.virtualMachinesProfile.scale.manual | Where-Object { $null -ne $_ }).Count -gt 0) {
    throw "Expected exactly the two documented fallback autoscale profiles, without manual profiles."
}
foreach ($Size in @('Standard_D8s_v5', 'Standard_D8s_v6')) {
    if (@($Profiles | Where-Object { $_.size -eq $Size -and $null -ne $_.minCount -and $_.minCount -eq 0 -and $_.maxCount -eq 3 }).Count -ne 1) {
        throw "Expected a single 0-3 autoscale profile for $Size."
    }
}

$NodesJson = Invoke-Kubernetes -Arguments @('get', 'nodes', '-o', 'json')
$Nodes = @(($NodesJson | ConvertFrom-Json -AsHashtable).items)
$PrimaryNodes = @($Nodes | Where-Object { $_.metadata.labels.'kubernetes.azure.com/agentpool' -eq 'appf8' })
$InitialFallbackNodes = @($Nodes | Where-Object { $_.metadata.labels.'kubernetes.azure.com/agentpool' -eq 'appfb' })
if ($InitialFallbackNodes.Count -ne 0) {
    throw "appfb must start at zero nodes to demonstrate new-node autoscaling. Inspect its pods and allow normal autoscaler scale-down; do not force-delete nodes or remove real workloads."
}
if ($PrimaryNodes.Count -ne $Primary.count) { throw "Azure and Kubernetes primary node counts differ; wait for a stable cluster before testing." }
$TotalPrimaryCpu = 0L
$CpuPerPod = 5000
$PrimaryPodSlots = 0
foreach ($Node in $PrimaryNodes) {
    if (@($Node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -ne 1 -or
        $Node.spec.unschedulable -or $Node.metadata.labels.workload -ne 'hello-world') {
        throw "All primary nodes must be Ready, schedulable, and labeled workload=hello-world."
    }
    $NodeCpu = Get-CpuMillis -Quantity $Node.status.allocatable.cpu
    $TotalPrimaryCpu += $NodeCpu
    $PrimaryPodSlots += [int][math]::Floor($NodeCpu / $CpuPerPod)
}
$Replicas = $PrimaryPodSlots + 2
if ($Replicas -gt 20) { throw "Calculated test demand exceeds the safety limit of 20 pods; use a smaller non-production cluster." }
if ($PrimaryPodSlots -lt 1) { throw "No primary node can accommodate a 5-CPU test pod; review node sizes before continuing." }

$RunId = [guid]::NewGuid().ToString('N')
$Namespace = "fallback-test-$($RunId.Substring(0, 12))"
if (-not $RecoveryPath) { $RecoveryPath = Join-Path ([IO.Path]::GetTempPath()) "$Namespace.json" }
$RecoveryPath = [IO.Path]::GetFullPath($RecoveryPath)
$Recovery = @{
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroup
    clusterName = $ClusterName
    primaryPool = 'appf8'
    context = $Context
    kubeconfig = [IO.Path]::GetFullPath($Kubeconfig)
    namespace = $Namespace
    originalMinCount = $Primary.minCount
    originalMaxCount = $Primary.maxCount
    testMaxCount = $Primary.count
    testReplicas = $Replicas
    cpuRequestPerPod = '5'
    completed = $false
}
$RecoveryStream = [IO.File]::Open($RecoveryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $Bytes = [text.encoding]::UTF8.GetBytes(($Recovery | ConvertTo-Json))
    $RecoveryStream.Write($Bytes, 0, $Bytes.Length)
} finally {
    $RecoveryStream.Dispose()
}
Write-Output "Recovery state saved to: $RecoveryPath"
Write-Output "TEST: cap appf8 at $($Primary.count) nodes; its $TotalPrimaryCpu allocatable millicores fit at most $PrimaryPodSlots test pods."
Write-Output "Requesting $Replicas x 5 CPUs: at least two pods must use fallback, and each 8-vCPU D8s node can fit at most one."
Write-Output "Initial fallback nodes: 0. Test pods reserve CPU but do not generate CPU load."
Write-Output "Test namespace: $Namespace"

$BoundsAttempted = $false
$NamespaceAttempted = $false
$Failure = $null
$CleanupErrors = [System.Collections.Generic.List[string]]::new()
try {
    $BoundsAttempted = $true
    Set-PrimaryBounds -Minimum $Primary.minCount -Maximum $Primary.count
    $NamespaceAttempted = $true
    Invoke-Kubernetes -Arguments @('create', 'namespace', $Namespace) | Out-Null
    $Manifest = @{
        apiVersion = 'apps/v1'
        kind = 'Deployment'
        metadata = @{ name = 'fallback-demand'; namespace = $Namespace }
        spec = @{
            replicas = $Replicas
            selector = @{ matchLabels = @{ app = 'fallback-demand' } }
            template = @{
                metadata = @{ labels = @{ app = 'fallback-demand' } }
                spec = @{
                    automountServiceAccountToken = $false
                    nodeSelector = @{ workload = 'hello-world' }
                    affinity = @{ nodeAffinity = @{
                        requiredDuringSchedulingIgnoredDuringExecution = @{ nodeSelectorTerms = @(
                            @{ matchExpressions = @(@{ key = 'kubernetes.azure.com/agentpool'; operator = 'In'; values = @('appf8', 'appfb') }) }
                        ) }
                        preferredDuringSchedulingIgnoredDuringExecution = @(
                            @{ weight = 100; preference = @{ matchExpressions = @(@{ key = 'kubernetes.azure.com/agentpool'; operator = 'In'; values = @('appf8') }) } }
                        )
                    } }
                    securityContext = @{ runAsNonRoot = $true; runAsUser = 65532; runAsGroup = 65532; seccompProfile = @{ type = 'RuntimeDefault' } }
                    containers = @(@{
                        name = 'pause'
                        image = 'registry.k8s.io/pause:3.10'
                        resources = @{ requests = @{ cpu = '5'; memory = '128Mi' }; limits = @{ cpu = '5'; memory = '128Mi' } }
                        securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
                    })
                }
            }
        }
    } | ConvertTo-Json -Depth 25
    Invoke-Kubernetes -Arguments @('apply', '--dry-run=server', '-f', '-') -InputJson $Manifest | Out-Null
    Invoke-Kubernetes -Arguments @('apply', '-f', '-') -InputJson $Manifest | Out-Null
    Write-Output "Watching test pods for up to $TimeoutMinutes minutes. Other workloads are not modified."
    $Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $FallbackPods = @()
    $ObservedFallbackNodes = @{}
    $OccupiedFallbackNodes = @()
    do {
        $PodJson = Invoke-Kubernetes -Arguments @('-n', $Namespace, 'get', 'pods', '-l', 'app=fallback-demand', '-o', 'json')
        $Pods = @(($PodJson | ConvertFrom-Json -AsHashtable).items)
        $CurrentNodeJson = Invoke-Kubernetes -Arguments @('get', 'nodes', '-o', 'json')
        $CurrentNodes = @(($CurrentNodeJson | ConvertFrom-Json -AsHashtable).items)
        foreach ($Node in @($CurrentNodes | Where-Object { $_.metadata.labels.'kubernetes.azure.com/agentpool' -eq 'appfb' })) {
            if (-not $ObservedFallbackNodes.ContainsKey($Node.metadata.name)) {
                $ObservedFallbackNodes[$Node.metadata.name] = [pscustomobject]@{
                    Node = $Node.metadata.name
                    SKU = $Node.metadata.labels.'node.kubernetes.io/instance-type'
                    FirstObservedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    CreatedUtc = $Node.metadata.creationTimestamp
                }
                Write-Output "NODE OBSERVED: $($Node.metadata.name), SKU $($Node.metadata.labels.'node.kubernetes.io/instance-type')."
            }
        }
        $ReadyFallbackNodes = @($CurrentNodes | Where-Object {
            $_.metadata.labels.'kubernetes.azure.com/agentpool' -eq 'appfb' -and
            $_.metadata.labels.'node.kubernetes.io/instance-type' -in @('Standard_D8s_v5', 'Standard_D8s_v6') -and
            @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1
        })
        $ReadyPods = @($Pods | Where-Object {
            $_.status.phase -eq 'Running' -and
            @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1
        })
        $FallbackPods = @($ReadyPods | Where-Object { $_.spec.nodeName -in @($ReadyFallbackNodes | ForEach-Object { $_.metadata.name }) })
        $OccupiedFallbackNodes = @($ReadyFallbackNodes | Where-Object {
            $_.metadata.name -in @($FallbackPods | ForEach-Object { $_.spec.nodeName })
        })
        Write-Output "Ready test pods: $($ReadyPods.Count)/$Replicas; Ready fallback nodes: $($ReadyFallbackNodes.Count); fallback nodes hosting Ready test pods: $($OccupiedFallbackNodes.Count)/2 required."
        if ($ReadyPods.Count -eq $Replicas -and $OccupiedFallbackNodes.Count -ge 2) { break }
        if ((Get-Date) -lt $Deadline) { Start-Sleep -Seconds 15 }
    } while ((Get-Date) -lt $Deadline)
    if ($ReadyPods.Count -ne $Replicas -or $OccupiedFallbackNodes.Count -lt 2) {
        Invoke-Kubernetes -Arguments @('-n', $Namespace, 'get', 'pods', '-o', 'wide') | Out-Host
        Invoke-Kubernetes -Arguments @('-n', $Namespace, 'get', 'events', '--sort-by=.metadata.creationTimestamp') | Out-Host
        throw "Timed out before all demand pods were Ready on at least two distinct Ready appfb nodes. Inspect capacity, quota, image access, taints, and autoscaler diagnostics."
    }
    $After = Read-Pool -Name 'appf8'
    if ($After.maxCount -ne $Primary.count -or $After.count -gt $Primary.count) {
        throw "Primary growth cap changed during the test; cannot confirm the intended scenario."
    }
    foreach ($Pod in $FallbackPods) {
        $Node = $ReadyFallbackNodes | Where-Object { $_.metadata.name -eq $Pod.spec.nodeName } | Select-Object -First 1
        Write-Output "VERIFIED: $($Pod.metadata.name) is Ready on $($Node.metadata.name), SKU $($Node.metadata.labels.'node.kubernetes.io/instance-type')."
    }
    Write-Output "VERIFIED: appfb grew from zero to at least $($OccupiedFallbackNodes.Count) Ready nodes hosting test pods."
    $ObservedFallbackNodes.Values | Sort-Object FirstObservedUtc, Node | Format-Table -AutoSize | Out-Host
    $SkuSummary = @($OccupiedFallbackNodes |
        Group-Object { $_.metadata.labels.'node.kubernetes.io/instance-type' } |
        ForEach-Object { [pscustomobject]@{ SKU = $_.Name; ReadyNodesHostingTestPods = $_.Count } })
    $SkuSummary | Format-Table -AutoSize | Out-Host
    Write-Output "SKU choices above are observations from this run, not a configured SKU preference. Both fallback profiles match priority 10."
    Write-Output "Nodes may be provisioned concurrently; first observed does not prove which SKU Azure attempted first."
    $Recovery.observedFallbackNodes = @($ObservedFallbackNodes.Values | Sort-Object FirstObservedUtc, Node)
    $Recovery.readyFallbackSkuSummary = $SkuSummary
    $Recovery | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RecoveryPath -Encoding utf8

    if (-not $SkipInspectionPause) {
        Write-Output "INSPECTION PAUSE: the test pods are still running and appf8 growth remains capped."
        Write-Output "Use a second terminal with kubeconfig '$Kubeconfig', context '$Context', and namespace '$Namespace'."
        Write-Output "Inspect nodes, pods, events and autoscaler status before continuing. Test nodes remain billable while paused."
        Read-Host "Press ENTER when finished inspecting to delete test pods and restore the original primary bounds" | Out-Null
    } else {
        Write-Output "Inspection pause explicitly skipped."
    }
} catch {
    $Failure = $_
} finally {
    if ($NamespaceAttempted) {
        try {
            Invoke-Kubernetes -Arguments @('delete', 'namespace', $Namespace, '--ignore-not-found=true', '--wait=true', '--timeout=120s') | Out-Null
        } catch {
            $CleanupErrors.Add("Test namespace cleanup failed: $($_.Exception.Message)")
        }
    }
    if ($BoundsAttempted) {
        try {
            Wait-PrimaryPool
            $Current = Read-Pool -Name 'appf8'
            if ($Current.minCount -ne $Primary.minCount -or $Current.maxCount -notin @($Primary.count, $Primary.maxCount)) {
                throw "Primary bounds were changed by another operator; refusing to overwrite them automatically."
            }
            Set-PrimaryBounds -Minimum $Primary.minCount -Maximum $Primary.maxCount
            Write-Output "RESTORED: appf8 autoscaler bounds $($Primary.minCount)-$($Primary.maxCount)."
        } catch {
            $CleanupErrors.Add("Primary bounds restoration failed: $($_.Exception.Message)")
        }
    }
    if ($CleanupErrors.Count -eq 0) {
        $Recovery.completed = $true
        $Recovery | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RecoveryPath -Encoding utf8
        Write-Output "CLEANUP COMPLETE: test namespace removed; Hello World was not changed. Recovery record: $RecoveryPath"
    } else {
        foreach ($CleanupError in $CleanupErrors) { Write-Warning $CleanupError }
        Write-Warning "Manual recovery required using $RecoveryPath. Do not rerun until the prior test is cleaned up."
    }
}
if ($CleanupErrors.Count -gt 0) {
    $FailureText = if ($Failure) { $Failure.Exception.Message } else { 'Scheduling checks completed.' }
    throw "$FailureText Cleanup/restoration is incomplete: $($CleanupErrors -join '; ')"
}
if ($Failure) { throw $Failure }
Write-Output "PASS: controlled fallback exercise and restoration completed. Nodes may remain billable until normal autoscaler scale-down."

# If the process is forcibly terminated, use the saved JSON and README recovery commands.
# Never delete a real application namespace or force node counts to zero to clean up this test.
