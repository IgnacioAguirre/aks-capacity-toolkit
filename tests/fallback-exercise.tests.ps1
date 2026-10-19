#requires -Version 7.2
# Offline regression checks. Run: pwsh -NoProfile -File .\tests\fallback-exercise.tests.ps1
# All az/kubectl calls and polling delays are mocked; no cloud resources are accessed.
$ErrorActionPreference = 'Stop'
$ScriptPath = Join-Path $PSScriptRoot '..\scripts\Test-AksFallback.ps1'
$TestDirectory = Join-Path ([IO.Path]::GetTempPath()) "aks-fallback-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TestDirectory | Out-Null
$ConfigFile = Join-Path $TestDirectory 'config'
Set-Content -LiteralPath $ConfigFile -Value 'offline mock kubeconfig'
$RecoveryFiles = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-Argument {
    param([object[]]$Arguments, [string]$Name)
    $Index = [array]::IndexOf($Arguments, $Name)
    if ($Index -lt 0) { throw "Missing mock argument: $Name" }
    return $Arguments[$Index + 1]
}

function New-MockNode {
    param([string]$Pool, [string]$Name, [string]$Cpu = '7800m')
    return @{
        metadata = @{ name = $Name; creationTimestamp = '2026-10-18T10:00:00Z'; labels = @{
            'kubernetes.azure.com/agentpool' = $Pool
            'node.kubernetes.io/instance-type' = $(if ($Pool -eq 'appfb') { 'Standard_D8s_v5' } else { 'Standard_F8s_v2' })
            workload = 'hello-world'
        } }
        spec = @{}
        status = @{ allocatable = @{ cpu = $Cpu }; conditions = @(@{ type = 'Ready'; status = 'True' }) }
    }
}

function az {
    $Arguments = $args
    $Call = $Arguments -join ' '
    $global:LASTEXITCODE = 0
    $script:Mock.Calls.Add("az $Call")
    Assert-True ((Get-Argument $Arguments '--subscription') -eq 'mock-subscription') 'All Azure calls must target the explicit subscription'
    if ($Call -like 'aks show *') {
        return (@{
            provisioningState = 'Succeeded'
            fqdn = 'mock-aks.example.test'
            autoScalerProfile = @{ expander = $(if ($script:Mock.Case -eq 'wrong-expander') { 'random' } else { 'priority' }) }
        } | ConvertTo-Json -Depth 10)
    }
    if ($Call -like 'aks nodepool show *') {
        $Name = Get-Argument $Arguments '--name'
        if ($Name -eq 'appf8') {
            return (@{ provisioningState = 'Succeeded'; enableAutoScaling = $true;
                count = $(if ($script:Mock.Case -eq 'zero-primary') { 0 } else { $script:Mock.NodeCount });
                minCount = $script:Mock.Minimum; maxCount = $script:Mock.Maximum
            } | ConvertTo-Json)
        }
        if ($Name -eq 'appfb') {
            return (@{ provisioningState = 'Succeeded'; typePropertiesType = 'VirtualMachines'; mode = 'User';
                nodeLabels = @{ workload = 'hello-world' };
                virtualMachinesProfile = @{ scale = @{ manual = $null; autoscale = @(
                    @{ size = 'Standard_D8s_v5'; minCount = 0; maxCount = $(if ($script:Mock.Case -eq 'wrong-profile') { 1 } else { 3 }) },
                    @{ size = 'Standard_D8s_v6'; minCount = 0; maxCount = 3 }
                ) } }
            } | ConvertTo-Json -Depth 10)
        }
    }
    if ($Call -like 'aks nodepool update *') {
        $Maximum = [int](Get-Argument $Arguments '--max-count')
        $script:Mock.Writes++
        $script:Mock.Updates.Add($Maximum)
        if ($Maximum -eq 3 -and $script:Mock.Case -eq 'restore-fails') {
            $global:LASTEXITCODE = 1
            return
        }
        $script:Mock.Maximum = $Maximum
        $script:Mock.Minimum = [int](Get-Argument $Arguments '--min-count')
        if ($Maximum -ne 3 -and $script:Mock.Case -eq 'cap-fails-after-write') {
            $global:LASTEXITCODE = 1
        }
        return
    }
    if ($Call -like 'aks wait *' -or $Call -like 'aks nodepool wait *') { return }
    throw "Unexpected Azure mock call: $Call"
}

function kubectl {
    $Payload = @($input) -join "`n"
    $Arguments = $args
    $Call = $Arguments -join ' '
    $global:LASTEXITCODE = 0
    $script:Mock.Calls.Add("kubectl $Call")
    Assert-True ((Get-Argument $Arguments '--context') -eq 'mock-context') 'All Kubernetes calls must use the explicit context'
    if ($Call -like '* config view *') {
        $HostName = if ($script:Mock.Case -eq 'wrong-context') { 'another.example.test' } else { 'mock-aks.example.test' }
        return (@{ clusters = @(@{ cluster = @{ server = "https://$HostName" } }) } | ConvertTo-Json -Depth 10)
    }
    if ($Call -like '* get configmap cluster-autoscaler-priority-expander *') {
        return (@{ data = @{ priorities = "50:`n  - .*appf8.*`n10:`n  - .*appfb.*" } } | ConvertTo-Json)
    }
    if ($Call -like '* get nodes *') {
        $Nodes = @()
        for ($Index = 0; $Index -lt $script:Mock.NodeCount; $Index++) {
            $Nodes += New-MockNode 'appf8' "primary-$Index" $script:Mock.Cpu
        }
        if ($script:Mock.Case -eq 'node-not-ready') { $Nodes[0].status.conditions[0].status = 'False' }
        if ($script:Mock.Case -eq 'existing-fallback' -or $script:Mock.Applied) { $Nodes += New-MockNode 'appfb' 'fallback-0' }
        if ($script:Mock.Applied -and $script:Mock.Case -ne 'one-fallback-node') {
            $FallbackNode = New-MockNode 'appfb' 'fallback-1'
            if ($script:Mock.Case -eq 'mixed-skus') { $FallbackNode.metadata.labels.'node.kubernetes.io/instance-type' = 'Standard_D8s_v6' }
            if ($script:Mock.Case -eq 'wrong-sku') { $FallbackNode.metadata.labels.'node.kubernetes.io/instance-type' = 'Standard_D4s_v5' }
            if ($script:Mock.Case -eq 'fallback-not-ready') { $FallbackNode.status.conditions[0].status = 'False' }
            $Nodes += $FallbackNode
        }
        return (@{ items = $Nodes } | ConvertTo-Json -Depth 15)
    }
    if ($Call -like '* create namespace *') {
        $script:Mock.Writes++
        $script:Mock.Namespace = $Arguments[-1]
        if ($script:Mock.Case -eq 'namespace-fails') { $global:LASTEXITCODE = 1 }
        return
    }
    if ($Call -like '* apply *') {
        $Manifest = $Payload | ConvertFrom-Json -AsHashtable
        Assert-True ($Manifest.metadata.namespace -like 'fallback-test-*') 'Demand must be isolated'
        Assert-True ($Manifest.spec.template.spec.containers[0].resources.requests.cpu -eq '5') 'Demand must reserve five CPUs per pod'
        Assert-True ($Manifest.spec.template.spec.nodeSelector.workload -eq 'hello-world') 'Demand must use application labels'
        $Allowed = $Manifest.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values
        Assert-True (($Allowed -join ',') -eq 'appf8,appfb') 'Do not force pods to fallback'
        $script:Mock.Replicas = $Manifest.spec.replicas
        $PrimarySlots = $script:Mock.NodeCount * [int][math]::Floor($script:Mock.CpuMillis / 5000)
        Assert-True ($script:Mock.Replicas -eq $PrimarySlots + 2) 'Demand must exceed primary per-node pod slots by exactly two'
        Assert-True (2 * 5000 -gt 8000) 'Each documented fallback SKU must fit at most one test pod'
        if ($Call -notlike '*--dry-run=server*') {
            $script:Mock.Writes++
            if ($script:Mock.Case -eq 'apply-fails') { $global:LASTEXITCODE = 1; return }
            $script:Mock.Applied = $true
        }
        return
    }
    if ($Call -like '* get pods *') {
        if ($Call -like '*-o wide*') { return 'mock pod diagnostics' }
        if ($script:Mock.Case -eq 'poll-fails') { $global:LASTEXITCODE = 1; return }
        $Pods = @()
        for ($Index = 0; $Index -lt $script:Mock.Replicas; $Index++) {
            $NodeName = if ($Index -ge $script:Mock.Replicas - 2) { "fallback-$($Index - ($script:Mock.Replicas - 2))" } else { "primary-$Index" }
            if ($script:Mock.Case -eq 'one-fallback-node' -or $script:Mock.Case -eq 'one-node-occupied') {
                if ($NodeName -like 'fallback-*') { $NodeName = 'fallback-0' }
            }
            if ($script:Mock.Case -eq 'primary-only') { $NodeName = 'primary-0' }
            $Ready = if ($script:Mock.Case -eq 'pending-timeout') { 'False' } else { 'True' }
            $Pods += @{ metadata = @{ name = "demand-$Index" }; spec = @{ nodeName = $NodeName };
                status = @{ phase = 'Running'; conditions = @(@{ type = 'Ready'; status = $Ready }) } }
        }
        if ($script:Mock.Case -eq 'concurrent-bounds') { $script:Mock.Maximum = 2 }
        return (@{ items = $Pods } | ConvertTo-Json -Depth 15)
    }
    if ($Call -like '* get events *') { return 'mock event diagnostics' }
    if ($Call -like '* delete namespace *') {
        $script:Mock.Writes++
        $script:Mock.Deleted = $true
        Assert-True ((Get-Argument $Arguments 'namespace') -eq $script:Mock.Namespace) 'Delete only the test namespace'
        if ($script:Mock.Case -eq 'cleanup-fails') { $global:LASTEXITCODE = 1 }
        return
    }
    throw "Unexpected Kubernetes mock call: $Call"
}

function Get-Date {
    $script:Mock.Clock = $script:Mock.Clock.AddSeconds(30)
    return $script:Mock.Clock
}

function Start-Sleep { }

function Read-Host {
    $script:Mock.Prompts++
    Assert-True $script:Mock.Applied 'Inspection must happen while test pods exist'
    Assert-True (-not $script:Mock.Deleted) 'Inspection must happen before namespace cleanup'
    Assert-True ($script:Mock.Maximum -eq $script:Mock.NodeCount) 'Inspection must happen before restoring primary bounds'
    $SavedForInspection = Get-Content -LiteralPath $RecoveryFile -Raw | ConvertFrom-Json
    Assert-True (@($SavedForInspection.observedFallbackNodes).Count -ge 2) 'Inspection recovery file must include observed nodes'
    if ($script:Mock.Case -eq 'prompt-fails') { throw 'Simulated inspection input failure' }
    return ''
}

try {
    foreach ($Case in @('success', 'mixed-skus', 'skip-pause', 'existing-fallback', 'cpu-in-cores', 'larger-primary', 'custom-bounds', 'no-consent',
            'wrong-context', 'wrong-expander', 'wrong-profile', 'zero-primary', 'node-not-ready',
            'too-many-pods', 'namespace-fails', 'apply-fails', 'poll-fails', 'pending-timeout',
            'primary-only', 'one-fallback-node', 'one-node-occupied', 'wrong-sku', 'fallback-not-ready',
            'prompt-fails', 'cap-fails-after-write', 'restore-fails', 'cleanup-fails', 'concurrent-bounds')) {
        $script:Mock = @{
            Case = $Case; Maximum = $(if ($Case -eq 'custom-bounds') { 5 } else { 3 });
            Minimum = $(if ($Case -eq 'custom-bounds') { 1 } else { 0 });
            NodeCount = $(if ($Case -eq 'larger-primary') { 2 } else { 1 });
            Cpu = $(if ($Case -eq 'cpu-in-cores') { '7.8' } elseif ($Case -eq 'too-many-pods') { '100000m' } else { '7800m' });
            CpuMillis = $(if ($Case -eq 'too-many-pods') { 100000 } else { 7800 });
            Calls = [System.Collections.Generic.List[string]]::new(); Updates = [System.Collections.Generic.List[int]]::new();
            Writes = 0; Applied = $false; Deleted = $false; Replicas = 0; Prompts = 0;
            Clock = [datetime]'2026-10-18T10:00:00Z'
        }
        $RecoveryFile = Join-Path $TestDirectory "$Case.json"
        $RecoveryFiles.Add($RecoveryFile)
        $Parameters = @{
            SubscriptionId = 'mock-subscription'; ResourceGroup = 'mock-rg'; ClusterName = 'mock-cluster';
            Context = 'mock-context'; Kubeconfig = $ConfigFile; RecoveryPath = $RecoveryFile;
            TimeoutMinutes = 5; AllowNonProductionChanges = ($Case -ne 'no-consent');
            SkipInspectionPause = ($Case -eq 'skip-pause')
        }
        $Failure = $null
        try { $Output = @(. $ScriptPath @Parameters 3>&1) } catch { $Failure = $_ }
        $ShouldPass = $Case -in @('success', 'mixed-skus', 'skip-pause', 'cpu-in-cores', 'larger-primary', 'custom-bounds')
        Assert-True (($null -eq $Failure) -eq $ShouldPass) "Unexpected result for ${Case}: $($Failure.Exception.Message) $($Failure.ScriptStackTrace)"
        $PreflightFailure = $Case -in @('no-consent', 'wrong-context', 'wrong-expander', 'wrong-profile', 'zero-primary', 'node-not-ready', 'too-many-pods', 'existing-fallback')
        if ($PreflightFailure) {
            Assert-True ($script:Mock.Writes -eq 0) "Preflight failure must not mutate anything: $Case"
            Assert-True (-not (Test-Path -LiteralPath $RecoveryFile)) 'Preflight failure must not save mutation state'
        } else {
            $Saved = Get-Content -LiteralPath $RecoveryFile -Raw | ConvertFrom-Json
            $ExpectedMinimum = if ($Case -eq 'custom-bounds') { 1 } else { 0 }
            $ExpectedMaximum = if ($Case -eq 'custom-bounds') { 5 } else { 3 }
            Assert-True ($Saved.originalMinCount -eq $ExpectedMinimum -and $Saved.originalMaxCount -eq $ExpectedMaximum) 'Recovery must retain original bounds'
            if ($Case -notin @('restore-fails', 'concurrent-bounds')) {
                Assert-True ($script:Mock.Maximum -eq $ExpectedMaximum -and $script:Mock.Minimum -eq $ExpectedMinimum) "Primary bounds must be restored: $Case"
            }
            if ($Case -ne 'cap-fails-after-write') { Assert-True $script:Mock.Deleted "Test namespace must be cleaned up: $Case" }
            Assert-True ($Saved.completed -eq ($Case -notin @('restore-fails', 'cleanup-fails', 'concurrent-bounds'))) 'Recovery must report incomplete cleanup honestly'
            if ($ShouldPass) {
                Assert-True (($Output -join "`n") -match 'PASS: controlled fallback exercise') 'Success requires the final PASS message'
                Assert-True (($Output -join "`n") -match 'VERIFIED: appfb grew from zero to at least 2') 'Success must prove at least two fallback nodes'
                Assert-True (@($Saved.observedFallbackNodes).Count -eq 2) 'Save the actual observed node evidence'
                $ExpectedSkuKinds = if ($Case -eq 'mixed-skus') { 2 } else { 1 }
                Assert-True (@($Saved.readyFallbackSkuSummary).Count -eq $ExpectedSkuKinds) 'Report actual SKU distribution, not an assumed mix'
                Assert-True (($Saved.readyFallbackSkuSummary | Measure-Object -Property ReadyNodesHostingTestPods -Sum).Sum -eq 2) 'SKU counts must cover both occupied nodes'
            }
        }
        $ExpectedPrompts = if (($ShouldPass -and $Case -ne 'skip-pause') -or $Case -in @('prompt-fails', 'restore-fails', 'cleanup-fails')) { 1 } else { 0 }
        Assert-True ($script:Mock.Prompts -eq $ExpectedPrompts) "Unexpected inspection pause count for $Case"
        Assert-True (@($script:Mock.Calls | Where-Object { $_ -match 'hello-world.*(scale|apply|delete)|operation-abort' }).Count -eq 0) 'Do not modify Hello World or abort operations'
        Write-Output "PASS: $Case"
    }
} finally {
    foreach ($File in $RecoveryFiles) {
        if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File }
    }
    Remove-Item -LiteralPath $ConfigFile
    Remove-Item -LiteralPath $TestDirectory
}
Write-Output 'PASS: all offline fallback exercise regression checks completed.'
