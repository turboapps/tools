# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Tool to help build a txt file to be used as input for --route-file parameter to new/run/start/commit commands.

.DESCRIPTION

This cmdlet will run a browser with the specified urls allowing you to test if all the necessary hosts/ips are unblocked.

If you see that the site(s) don't load or render properly, then simply exit the browser and answer "no" at the prompt. The browser will launch again with additional settings. Repeat this process until everything appears to work.

Use the output file with the turbo new/run/start/commmit command via the --route-file= flag...

> turbo new firefox --route-block=ip --route-file=c:\path\to\routes.txt

Requires the Turbo.net client to be installed.

.PARAMETER urls

An array of urls that need to be tested.

.PARAMETER routeFile

A path to a file which will receive the routes file data. If not specified, the data will be written to the console and can be redirect to a file at that time.

#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory=$True,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The starter urls")]
    [string[]] $urls,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The file to receive the routes information")]
    [string] $routeFile
)

# returns a list of blocked hosts/ips to unblock.
function GetBlocked([string]$container) {
    # find all the network logs for the container
    $logsDir = Join-Path -path $env:LOCALAPPDATA -ChildPath "spoon\containers\sandboxes\$container\logs"
    $logs = Get-ChildItem $logsDir | 
                Where { $_.Name.StartsWith("xcnetwork_") } | 
                Select @{Name="path"; Expression={ Join-Path -path $logsDir -childpath $_.Name }} | 
                Select -ExpandProperty path


    $hostmap = @{}
    $blocked = @()
    ForEach($log in $logs) {
        $lines = Get-Content $log

        ForEach($line in $lines) {
            if($line -match 'Host (.*) resolved to: (.*)') { 
                # keep track of host->ip mappings that we encounter
                $hostname = $matches[1]
                $ip = $matches[2]
                if($ip -match '::ffff:(\d+\.\d+\.\d+\.\d+)') {
                    # parse ipv6 mapped ipv4
                    $ip = $matches[1] 
                }
                $hostmap.set_item($ip, $hostname)
            }
            elseif($line -match 'Connection blocked: (.*)') {
                # track blocked connections
                $ip = $matches[1]
                if($hostmap.ContainsKey($ip)) {
                    # resolve the ip to a host if we know what it is
                    $hostorip = $hostmap."$ip"
                    if ([System.Uri]::CheckHostName($hostorip) -ne 'Unknown') {
                        $ip = $hostorip
                    }
                }
                $blocked += ,$ip
            }
        }
    }

    $blocked | select -Unique
}

# writes a route file based on the list of blocked ip/hosts. if the route file already exists, then the new blocked entries are merged in.
function BuildRouteFile([string]$routeFile, [string[]]$unblock, [string[]]$block) {
    
    $routes = @{}

    # read in the existing route file
    if(Test-Path $routeFile) {
        $lines = Get-Content $routeFile

        $section = ""
        $list = @()
        ForEach ($line in $lines) {
            if($line -match '\[(.*)\]') {
                if($section) {
                    $routes.add($section, $list)
                    $list = @()
                }
                $section = $matches[1]
            }
            elseif($line.Length -gt 0) {
                $list += ,$line
            }
        }
        if($section) {
            $routes.add($section, $list)
        }

        # clear previous content 
        Clear-Content $routeFile
    }

    # merge
    if($unblock) {
        MergeRouteFileSection $routes "ip-add" $unblock
    }
    if($block) {
        MergeRouteFileSection $routes "ip-block" $block
    }
    
    # write new file
    ForEach ($section in $routes.Keys) {
        Add-Content $routeFile "[$section]"
        $list = $routes."$section"
        ForEach ($ip in $list) {
            Add-Content $routeFile $ip
        }
        Add-Content $routeFile ""
    }
}

function MergeRouteFileSection([hashtable]$routes, [string]$section, [string[]]$new) {

    if($routes.ContainsKey($section)) {
        $list = $routes."$section"
    }
    ForEach($n in $new) {
        $list += ,$n
    }
    $list = $list | select -Unique
    $routes.set_item($section, $list)
}

# runs a browser with the defined routes. returns the container id.
function RunBrowser([string]$urls, [string]$routeFile, [string]$containerToResume, [string]$browser = "firefox") {
    if(-not $containerToResume) {
        $params = ,"new $browser"
    }
    else {
        $params = ,"start $containerToResume"
    }

    $params += ,"--format=json"
    $params += ,"--diagnostic"

    $params += ,"--route-file=`"$routeFile`""

    $params += ,"--"
    ForEach ($url in $urls) {
        $params += ,"$url"
    }

    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        Start-Process -FilePath "turbo" -ArgumentList $params -Wait -RedirectStandardOutput $tempFile -WindowStyle Hidden
        $ret = Get-Content $tempFile | ConvertFrom-Json
    }
    finally {
        # clean up
        Remove-Item $tempFile
    }

    $ret.result.container.id
}

function GetHostName([string] $str) {
    $str = $str.Trim("""") # trim off quotes if entered with them
    $url = ([System.Uri]$str)
    if(-not $url.AbsoluteUri) {
        # wasn't a valid url, so let's try something easy to see if we can make one
        $url = ([System.Uri]"http://$str")
        if(-not $url.AbsoluteUri) {
            Write-Error """$str"" is not a valid url"
            return ""
        }
    }

    $url.Host -replace '^www\.'
}



try {
    # initialize routes file
    $routesToAdd = @()
    $routesToBlock = @("0.0.0.0")
    ForEach ($url in $urls) {
        $hostname = GetHostName($url)
        if($hostname) {
            $routesToAdd += ,"*.$hostname"
        }
    }
    
    # use temp file if we didn't specify one
    $tempFile = ""
    if(-not $routeFile) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $routeFile = $tempFile
    }
    
    # loop until we find everything we need to unblock
    $container = ""
    $continue = "n"
    while(-not $continue.StartsWith("y")) {
        BuildRouteFile $routeFile $routesToAdd $routesToBlock

        Write-Host "Running browser..."
        $container = RunBrowser $urls $routeFile $container

        $blocked = GetBlocked $container
        $routesToAdd += $blocked

        $continue = (Read-Host -Prompt "Did everything work correctly? (y/n)").ToLower()
    }

    Write-Host ""

    # output temp file to console if we didn't have a file specified
    if($tempFile) {
        Get-Content $tempFile
    }
}
finally {
    # clean up
    if($tempFile -and $(Test-Path $tempFile)) {
        Remove-Item $tempFile
    }
}
