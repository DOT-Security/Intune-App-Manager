$script:log_root='C:\ProgramData\DOTSecurity\IntuneAppDeployment\logs';
$script:winget_no_applicable_update_exit_code=-1978335189;
$script:loaded_temp_hive_names=@();
function write_app_log{
    param([string]$script_name,[string[]]$lines)
    if($lines.count -eq 0){return;}
    try{
        if(-not (test-path $script:log_root)){new-item -itemtype directory -path $script:log_root -force|out-null;}
        $log_path=join-path $script:log_root "$script_name.log";
        $timestamp=get-date -format 'yyyy-MM-dd HH:mm:ss';
        $stamped_lines=$lines|foreach-object{"$timestamp`t$_"};
        add-content -path $log_path -value $stamped_lines -encoding utf8;
    }catch{}
}
function resolve_winget_executable_path{
    $winget_command=get-command winget.exe -erroraction silentlycontinue;
    if($winget_command){return $winget_command.source;}
    $desktop_app_installer_directory=get-childitem "$env:programfiles\windowsapps" -filter 'microsoft.desktopappinstaller_*_x64__8wekyb3d8bbwe' -directory -erroraction silentlycontinue|sort-object name -descending|select-object -first 1;
    if($desktop_app_installer_directory){return join-path $desktop_app_installer_directory.fullname 'winget.exe';}
    return $null;
}
function install_or_upgrade_package{
    param([string]$winget_executable_path,[string]$package_id,[string]$target_scope='system')
    $is_installed=& $winget_executable_path list --exact --id $package_id --accept-source-agreements|select-string -simplematch $package_id;
    if($is_installed){
        & $winget_executable_path upgrade --exact --id $package_id --silent --accept-source-agreements --accept-package-agreements --disable-interactivity;
        return $LASTEXITCODE;
    }
    & $winget_executable_path install --exact --id $package_id --silent --scope $target_scope --accept-source-agreements --accept-package-agreements --disable-interactivity;
    return $LASTEXITCODE;
}
function get_user_profile_hive_roots{
    $profiles=@();
    $loaded_sids=get-childitem 'Registry::HKEY_USERS' -erroraction silentlycontinue|where-object{$_.pschildname -match '^S-1-5-21-\d+-\d+-\d+-\d+$'}|select-object -expandproperty pschildname;
    foreach($sid in $loaded_sids){$profiles+=[pscustomobject]@{sid=$sid;hive_root="Registry::HKEY_USERS\$sid"};}
    $profile_list_keys=get-childitem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -erroraction silentlycontinue;
    foreach($profile_key in $profile_list_keys){
        $sid=$profile_key.pschildname;
        if($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$'){continue;}
        if($loaded_sids -contains $sid){continue;}
        $profile_image_path=(get-itemproperty -path $profile_key.pspath -name 'ProfileImagePath' -erroraction silentlycontinue).profileimagepath;
        if(-not $profile_image_path){continue;}
        $ntuser_dat_path=join-path $profile_image_path 'NTUSER.DAT';
        if(-not (test-path $ntuser_dat_path -erroraction silentlycontinue)){continue;}
        $temp_hive_name="TEMP_HIVE_$sid";
        & reg.exe load "HKU\$temp_hive_name" $ntuser_dat_path *>$null;
        if($LASTEXITCODE -eq 0){
            $profiles+=[pscustomobject]@{sid=$sid;hive_root="Registry::HKEY_USERS\$temp_hive_name"};
            $script:loaded_temp_hive_names+=$temp_hive_name;
        }
    }
    return $profiles;
}
function unload_temp_hives{
    if($script:loaded_temp_hive_names.count -eq 0){return;}
    [gc]::Collect();
    [gc]::WaitForPendingFinalizers();
    foreach($temp_hive_name in $script:loaded_temp_hive_names){
        & reg.exe unload "HKU\$temp_hive_name" *>$null;
    }
    $script:loaded_temp_hive_names=@();
}
function scan_uninstall_root{
    param([string]$root,[string[]]$display_patterns,[string]$scope,[string]$sid)
    $entries=@();
    $subkeys=get-childitem $root -erroraction silentlycontinue;
    foreach($subkey in $subkeys){
        $properties=get-itemproperty -path $subkey.pspath -erroraction silentlycontinue;
        if(-not $properties.displayname){continue;}
        $matches_any=$false;
        foreach($pattern in $display_patterns){if($properties.displayname -like $pattern){$matches_any=$true;break;}}
        if(-not $matches_any){continue;}
        $entries+=[pscustomobject]@{
            display_name=$properties.displayname;
            display_version=$properties.displayversion;
            uninstall_string=$properties.uninstallstring;
            quiet_uninstall_string=$properties.quietuninstallstring;
            registry_path=$subkey.pspath;
            scope=$scope;
            sid=$sid;
            package_full_name=$null;
        };
    }
    return $entries;
}
function get_arp_entries_scoped{
    param([string[]]$display_patterns=@('*'))
    $entries=@();
    $machine_roots=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall');
    foreach($root in $machine_roots){
        $entries+=scan_uninstall_root -root $root -display_patterns $display_patterns -scope 'system' -sid $null;
    }
    foreach($user_profile in get_user_profile_hive_roots){
        $user_root=join-path $user_profile.hive_root 'Software\Microsoft\Windows\CurrentVersion\Uninstall';
        $entries+=scan_uninstall_root -root $user_root -display_patterns $display_patterns -scope 'user' -sid $user_profile.sid;
    }
    return $entries;
}
function get_appx_entries_scoped{
    param([string]$appx_name_pattern)
    if(-not $appx_name_pattern){return @();}
    $entries=@();
    try{
        $packages=get-appxpackage -allusers -name $appx_name_pattern -erroraction stop;
    }catch{
        $packages=@();
    }
    foreach($package in $packages){
        $entries+=[pscustomobject]@{
            display_name=$package.name;
            display_version=$package.version.tostring();
            uninstall_string=$null;
            quiet_uninstall_string=$null;
            registry_path=$null;
            scope='store';
            sid=$null;
            package_full_name=$package.packagefullname;
        };
    }
    return $entries;
}
function stop_known_processes{
    param([string[]]$process_names)
    foreach($process_name in $process_names){
        get-process -name $process_name -erroraction silentlycontinue|stop-process -force -erroraction silentlycontinue;
    }
}
function invoke_arp_uninstall{
    param($instance)
    try{
        if($instance.quiet_uninstall_string){
            & cmd.exe /c $instance.quiet_uninstall_string;
            return $LASTEXITCODE;
        }
        $uninstall_string=$instance.uninstall_string;
        if(-not $uninstall_string){return -1;}
        if($uninstall_string -match 'MsiExec\.exe'){
            $product_code_match=[regex]::match($uninstall_string,'\{[0-9A-Fa-f\-]+\}');
            if($product_code_match.success){
                & msiexec.exe /x $product_code_match.value /qn /norestart;
                return $LASTEXITCODE;
            }
        }
        if($uninstall_string -match 'unins\d*\.exe'){
            & cmd.exe /c "$uninstall_string /VERYSILENT /SUPPRESSMSGBOXES /NORESTART";
            return $LASTEXITCODE;
        }
        & cmd.exe /c "$uninstall_string /S";
        return $LASTEXITCODE;
    }catch{
        return -1;
    }
}
function invoke_uninstall_instance{
    param($instance,[string]$winget_executable_path)
    if($instance.scope -eq 'store'){
        try{
            remove-appxpackage -package $instance.package_full_name -allusers -erroraction stop;
            return 0;
        }catch{return -1;}
    }
    if($instance.package_id -and $winget_executable_path){
        & $winget_executable_path uninstall --exact --id $instance.package_id --scope $instance.scope --silent --accept-source-agreements --disable-interactivity *>$null;
        if($LASTEXITCODE -eq 0){return 0;}
    }
    return invoke_arp_uninstall -instance $instance;
}
function manage-app{
    param($app,[switch]${detect-only})
    $expected_scope=$app.expected_scope;
    if(-not $expected_scope){$expected_scope='system';}
    $winget_executable_path=resolve_winget_executable_path;
    if(-not $winget_executable_path){
        write-output 'winget not found';
        exit 1;
    }
    $issues=@();
    $actions_taken=@();
    $failures=@();
    try{
        $instances=@();
        if($app.display_patterns){$instances+=get_arp_entries_scoped -display_patterns $app.display_patterns;}
        if($app.appx_name_pattern){$instances+=get_appx_entries_scoped -appx_name_pattern $app.appx_name_pattern;}
        foreach($instance in $instances){$instance|add-member -membertype noteproperty -name 'package_id' -value $app.package_id -force;}
        $wrong_scope_instances=@($instances|where-object{$_.scope -ne $expected_scope});
        $matching_scope_instances=@($instances|where-object{$_.scope -eq $expected_scope});
        $keeper=$null;
        if($matching_scope_instances.count -gt 0){$keeper=$matching_scope_instances|sort-object display_version -descending|select-object -first 1;}
        $to_remove=@($wrong_scope_instances)+@($matching_scope_instances|where-object{$_ -ne $keeper});
        if($to_remove.count -gt 0){$issues+="$($to_remove.count) non-conforming/duplicate install(s) of $($app.name)";}
        $manage_via_winget=($expected_scope -ne 'store') -and $app.package_id;
        if($manage_via_winget){
            $installed_output=& $winget_executable_path list --exact --id $app.package_id --accept-source-agreements;
            $is_installed=$installed_output|select-string -simplematch $app.package_id;
            if(-not $is_installed -and -not $keeper){$issues+="missing: $($app.name)";}
            if($is_installed -or $keeper){
                $upgrade_output=& $winget_executable_path upgrade --exact --id $app.package_id --accept-source-agreements;
                $has_pending_upgrade=$upgrade_output|select-string -simplematch $app.package_id;
                if($has_pending_upgrade){$issues+="outdated: $($app.name)";}
            }
        }
        if(${detect-only}){
            if($issues.count -gt 0){write-output ($issues -join '; ');exit 1;}
            write-output 'compliant';
            exit 0;
        }
        foreach($item in $to_remove){
            $uninstall_exit_code=invoke_uninstall_instance -instance $item -winget_executable_path $winget_executable_path;
            if($uninstall_exit_code -eq 0){$actions_taken+="removed non-conforming copy: $($app.name) ($($item.scope), $($item.display_version))";}
            else{$failures+="removal failed: $($app.name) ($($item.scope), exit $uninstall_exit_code)";}
        }
        if($manage_via_winget){
            $package_exit_code=install_or_upgrade_package -winget_executable_path $winget_executable_path -package_id $app.package_id -target_scope $expected_scope;
            $is_success=($package_exit_code -eq 0) -or ($package_exit_code -eq $script:winget_no_applicable_update_exit_code);
            if($is_success){$actions_taken+="installed/upgraded: $($app.name)";}
            else{$failures+="install/upgrade failed: $($app.name) ($package_exit_code)";}
        }
    }finally{
        unload_temp_hives;
    }
    write_app_log -script_name "manage-app_$($app.name)" -lines ($actions_taken+$failures);
    if($failures.count -gt 0){write-output (($actions_taken+$failures) -join '; ');exit 1;}
    if($actions_taken.count -eq 0){write-output 'no action needed';exit 0;}
    write-output ($actions_taken -join '; ');
    exit 0;
}
function remove-app{
    param($app,[switch]${detect-only})
    $winget_executable_path=resolve_winget_executable_path;
    $actions_taken=@();
    $failures=@();
    try{
        $instances=@();
        if($app.display_patterns){$instances+=get_arp_entries_scoped -display_patterns $app.display_patterns;}
        if($app.appx_name_pattern){$instances+=get_appx_entries_scoped -appx_name_pattern $app.appx_name_pattern;}
        if(${detect-only}){
            if($instances.count -gt 0){write-output "unauthorized: $($app.name) ($($instances.count) install(s))";exit 1;}
            write-output 'compliant';
            exit 0;
        }
        if($instances.count -eq 0){write-output 'no action needed';exit 0;}
        stop_known_processes -process_names $app.process_names;
        foreach($instance in $instances){
            $uninstall_exit_code=invoke_uninstall_instance -instance $instance -winget_executable_path $winget_executable_path;
            if($uninstall_exit_code -eq 0){$actions_taken+="uninstalled: $($instance.display_name) ($($instance.scope))";}
            else{$failures+="uninstall failed: $($instance.display_name) ($($instance.scope), exit $uninstall_exit_code)";}
        }
    }finally{
        unload_temp_hives;
    }
    write_app_log -script_name "remove-app_$($app.name)" -lines ($actions_taken+$failures);
    if($failures.count -gt 0){write-output (($actions_taken+$failures) -join '; ');exit 1;}
    write-output ($actions_taken -join '; ');
    exit 0;
}