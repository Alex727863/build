#!/sbin/sh

abort() {
  ui_print " "
  ui_print "----------------------------------------------------"
  ui_print "$@"
  ui_print "----------------------------------------------------"
  ui_print " "
  exit_install
  exit 1
}

beginswith() {
  case $2 in
    "$1"*) echo true ;;
    *) echo false ;;
  esac
}

calculate_space() {
  local partitions="$*"
  for partition in $partitions; do
    addToLog " "
    if ! is_mounted "/$partition"; then
      continue
    fi
    addToLog "--> Calculating space in /$partition"
    # Read and save system partition size details
    df=$(df -k /"$partition" | tail -n 1)
    addToLog "$df"
    case $df in
    /dev/block/*) df=$(echo "$df" | awk '{ print substr($0, index($0,$2)) }') ;;
    esac
    total_system_size_kb=$(echo "$df" | awk '{ print $1 }')
    used_system_size_kb=$(echo "$df" | awk '{ print $2 }')
    free_system_size_kb=$(echo "$df" | awk '{ print $3 }')
    addToLog "- Total System Size (KB) $total_system_size_kb"
    addToLog "- Used System Space (KB) $used_system_size_kb"
    addToLog "- Current Free Space (KB) $free_system_size_kb"
  done
}

ch_con() {
  chcon -h u:object_r:"${1}"_file:s0 "$2"
  addToLog "- ch_con with ${1} for $2"
}

check_if_partitions_are_mounted_rw() {
  addToLog "- Bootmode: $BOOTMODE"
  $BOOTMODE and return
  addToLog "- Android version: $androidVersion"
  case "$androidVersion" in
    "11")
      [ ! "$is_system_writable" ] && [ ! "$is_product_writable" ] && [ ! "$is_system_ext_writable" ] && abort "- Partitions not writable!"
    ;;
    "10")
      system_ext="";
      [ ! "$is_system_writable" ] && [ ! "$is_product_writable" ] && abort "- Partitions not writable!"
    ;;
    *)
      product=""; system_ext="";
      [ ! "$is_system_writable" ] && abort "- Partitions not writable!"
    ;;
  esac
}

check_if_system_mounted_rw() {
  is_partition_mounted_flag="false"
  for partition in "system" "product" "system_ext"; do
    is_partition_mounted="$(is_mounted_rw "$partition" 2>/dev/null)"
    if [ "$is_partition_mounted" = "true" ]; then
      ui_print "- /$partition is properly mounted as rw"
      is_partition_mounted_flag="true"
    else
      addToLog "----------------------------------------------------------------------------"
      addToLog "- $partition is not mounted as rw, Installation failed!"
      addToLog "----------------------------------------------------------------------------"
    fi
  done
  [ "$is_partition_mounted_flag" = "false" ] && abort "- System is not mounted as rw, Installation failed!"
}

clean_recursive() {
  func_result="$(beginswith / "$1")"
  addToLog "- Deleting $1 with func_result: $func_result"
  if [ "$func_result" = "true" ]; then
    addToLog "- Deleting $1"
    rm -rf "$1"
  else
    addToLog "- Deleting $1"
    # For Devices having symlinked product and system_ext partition
    for sys in "/system"; do
      for subsys in "/system" "/product" "/system_ext"; do
        for folder in "/app" "/priv-app"; do
          delete_recursive "$sys$subsys$folder/$1"
        done
      done
    done
    # For devices having dedicated product and system_ext partitions
    for subsys in "/system" "/product" "/system_ext"; do
      for folder in "/app" "/priv-app"; do
        delete_recursive "$subsys$folder/$1"
      done
    done
  fi
}

# This is meant to copy the files safely from source to destination
copy_file() {
  if [ -f "$1" ]; then
    mkdir -p "$(dirname "$2")"
    cp -f "$1" "$2"
  else
    addToLog "- File $1 does not exist!"
  fi
}

contains() {
  case $2 in
    *"$1"*) echo true ;;
    *) echo false ;;
  esac
}

copy_logs() {
  ui_print " "
  copy_file "$system/build.prop" "$logDir/propfiles/build.prop"
  # Store the size of partitions after installation starts
  df >"$COMMONDIR/size_after.txt"
  df -h >"$COMMONDIR/size_after_readable.txt"
  copy_file "/vendor/etc/fstab.qcom" "$logDir/fstab/fstab.qcom"
  copy_file "/etc/recovery.fstab" "$logDir/fstab/recovery.fstab"
  copy_file "/etc/fstab" "$logDir/fstab/fstab"
  copy_file "$COMMONDIR/size_after.txt" "$logDir/partitions/size_after.txt"
  copy_file "$COMMONDIR/size_after_readable.txt" "$logDir/partitions/size_after_readable.txt"
  ls -alR /system >"$logDir/partitions/System_Files_After.txt"
  ls -alR /product >"$logDir/partitions/Product_Files_After.txt"
  for f in $PROPFILES; do
    copy_file "$f" "$logDir/propfiles/$f"
  done
  for f in $addon_scripts_logDir; do
    copy_file "$f" "$logDir/addonscripts/$f"
  done
  calculate_space "system" "product" "system_ext"
  addToLog "- copying $debloater_config_file_name to log directory"
  copy_file "$debloater_config_file_name" "$logDir/configfiles/debloater.config"
  addToLog "- copying $nikgapps_config_file_name to log directory"
  copy_file "$nikgapps_config_file_name" "$logDir/configfiles/nikgapps.config"
  copy_file "$recoveryLog" "$logDir/logfiles/recovery.log"
  copy_file "$nikGappsLog" "$logDir/logfiles/NikGapps.log"
  copy_file "$busyboxLog" "$logDir/logfiles/busybox.log"
  cd "$logDir" || return
  rm -rf "$nikGappsDir"/logs
  tar -cz -f "$TMPDIR/$nikGappsLogFile" *
  rm -rf "$nikgapps_log_dir/nikgapps_logs"
  rm -rf "$nikgapps_config_dir/nikgapps_logs"
  [ -z "$nikgapps_config_dir" ] && nikgapps_config_dir=/sdcard/NikGapps
  copy_file "$TMPDIR/$nikGappsLogFile" "$nikGappsDir/logs/$nikGappsLogFile"
  copy_file "$TMPDIR/$nikGappsLogFile" "$nikgapps_config_dir/nikgapps_logs/$nikGappsLogFile"
  copy_file "$TMPDIR/$nikGappsLogFile" "$nikgapps_log_dir/$nikGappsLogFile"
  ui_print "- Copying Logs at $nikgapps_log_dir/$nikGappsLogFile"
  ui_print " "
  cd /
}

debloat() {
  debloaterFilesPath="DebloaterFiles"
  debloaterRan=0
  if [ -f "$debloater_config_file_name" ]; then
    addToLog "- Debloater.config found!"
    g=$(sed -e '/^[[:blank:]]*#/d;s/[\t\n\r ]//g;/^$/d' "$debloater_config_file_name")
    for i in $g; do
      if [ $debloaterRan = 0 ]; then
        ui_print " "
        ui_print "--> Running Debloater"
      fi
      value=$($i | grep "^WipeDalvikCache=" | cut -d'=' -f 1)
      if [ "$i" != "WipeDalvikCache" ]; then
        addToLog "- Deleting $i"
        if [ -z "$i" ]; then
          ui_print "Cannot delete blank folder!"
        else
          debloaterRan=1
          startswith=$(beginswith / "$i")
          ui_print "x Removing $i"
          if [ "$startswith" = "false" ]; then
            echo "debloat=$i" >>$TMPDIR/addon/$debloaterFilesPath
            addToLog "- value of i is $i"
            rmv "$system/app/$i"
            rmv "$system$product/app/$i"
            rmv "$system/priv-app/$i"
            rmv "$system$product/priv-app/$i"
            rmv "$system/system_ext/app/$i"
            rmv "$system/system_ext/priv-app/$i"
            rmv "/product/app/$i"
            rmv "/product/priv-app/$i"
            rmv "/system_ext/app/$i"
            rmv "/system_ext/priv-app/$i"
          else
            rmv "$i"
            echo "debloat=$i" >>$TMPDIR/addon/$debloaterFilesPath
          fi
        fi
      else
        addToLog "- WipeDalvikCache config found!"
      fi
    done
    if [ $debloaterRan = 1 ]; then
      . $COMMONDIR/addon "$OFD" "Debloater" "" "" "$TMPDIR/addon/$debloaterFilesPath" ""
      CopyFile "$system/addon.d/nikgapps/Debloater.sh" "$logDir/addonscripts/Debloater.sh"
      CopyFile "$TMPDIR/addon/$debloaterFilesPath" "$logDir/addonfiles/Debloater.addon"
      rmv "$TMPDIR/addon/$debloaterFilesPath"
    fi
  else
    addToLog "- Debloater.config not found!"
    unpack "afzc/debloater.config" "/sdcard/NikGapps/debloater.config"
  fi
}

delete_package() {
  addToLog "- Deleting package $1"
  clean_recursive "$1"
}

delete_package_data() {
  addToLog "- Deleting data of package $1"
  rm -rf "/data/data/${1}*"
}

delete_recursive() {
  addToLog "- rm -rf $*"
  rm -rf "$*"
}

extract_file() {
  mkdir -p "$(dirname "$3")"
  addToLog "- Unzipping $1"
  addToLog "  -> copying $2"
  addToLog "  -> to $3"
  $BB unzip -o "$1" "$2" -p >"$3"
}

exit_install() {
  rm -rf "$system/addon.d/$master_addon_file"
  addon_version_config=$(ReadConfigValue "addon_version.d" "$nikgapps_config_file_name")
  [ -n "$addon_version_config" ] && version=$addon_version_config
  [ -z "$addon_version_config" ] && version=3
#  echo "#!/sbin/sh" > "$system/addon.d/$master_addon_file"
#  echo "# ADDOND_VERSION=$version" >> "$system/addon.d/$master_addon_file"
#  cat "$COMMONDIR/nikgapps.sh" >> "$system/addon.d/$master_addon_file"
  ui_print " "
  wipedalvik=$(ReadConfigValue "WipeDalvikCache" "$nikgapps_config_file_name")
  addToLog "- WipeDalvikCache value: $wipedalvik"
  if [ "$wipedalvik" != 0 ]; then
    ui_print "- Wiping dalvik-cache"
    rm -rf "/data/dalvik-cache"
  fi
  ui_print "- Finished Installation"
  ui_print " "
  copy_logs
  restore_env
}

find_config() {
  ui_print " "
  ui_print "--> Finding config files"
  nikgapps_config_file_name="$nikGappsDir/nikgapps.config"
  for location in "/tmp" "$TMPDIR" "$ZIPDIR" "/sdcard1" "/sdcard1/NikGapps" "/sdcard" "/sdcard/NikGapps" "/storage/emulated" "/storage/emulated/NikGapps" "$COMMONDIR" ; do
    if [ -f "$location/nikgapps.config" ]; then
      nikgapps_config_file_name="$location/nikgapps.config"
      break;
    fi
  done
  nikgapps_config_dir=$(dirname "$nikgapps_config_file_name")
  debloater_config_file_name="/sdcard/NikGapps/debloater.config"
  for location in "/tmp" "$TMPDIR" "$ZIPDIR" "/sdcard1" "/sdcard1/NikGapps" "/sdcard" "/sdcard/NikGapps" "/storage/emulated" "/storage/emulated/NikGapps" "$COMMONDIR"; do
    if [ -f "$location/debloater.config" ]; then
      debloater_config_file_name="$location/debloater.config"
      break;
    fi
  done
  test "$zip_type" != "debloater" && ui_print "- nikgapps.config found in $nikgapps_config_file_name"
  test "$zip_type" = "debloater" && ui_print "- debloater.config found in $debloater_config_file_name"
}

find_install_mode() {
  if [ "$clean_flash_only" = "true" ] && [ "$install_type" = "dirty" ] && [ ! -f "$install_partition/etc/permissions/$package_title.prop" ]; then
    test "$zip_type" = "gapps" && ui_print "- Can't dirty flash $package_title" && return
    test "$zip_type" = "addon" && abort "- Can't dirty flash $package_title, please clean flash!"
  fi
  mode=$(ReadConfigValue "mode" "$nikgapps_config_file_name")
  [ -z "$mode" ] && mode="install"
  addToLog "- Install mode is $mode"
  if [ "$configValue" = "-1" ]; then
    ui_print "- Uninstalling $package_title"
    uninstall_package
  elif [ "$mode" = "install" ]; then
    addToLog "----------------------------------------------------------------------------"
    addToLog "- calculating space while working on $package_title"
    case "$install_partition" in
      "/product") product_size_left=$(get_available_size "product"); addToLog "- product_size_left=$product_size_left" ;;
      "/system_ext") system_ext_size_left=$(get_available_size "system_ext"); addToLog "- system_ext_size_left=$system_ext_size_left" ;;
      "/system"*) system_size_left=$(get_available_size "system"); addToLog "- system_size_left=$system_size_left"  ;;
    esac
    addToLog "----------------------------------------------------------------------------"
    ui_print "- Installing $package_title"
    install_package
    delete_recursive "$pkgFile"
    addToLog "----------------------------------------------------------------------------"
    addToLog "- calculating space after installing $package_title"
    total_size=$((system_size+product_size+system_ext_size))
    case "$install_partition" in
      "/product") product_size_after=$(get_available_size "product"); addToLog "- product_size ($pkg_size) spent=$((product_size_left-product_size_after))"; ;;
      "/system_ext") system_ext_size_after=$(get_available_size "system_ext"); addToLog "- system_ext_size ($pkg_size) spent=$((system_ext_size_left-system_ext_size_after))"; ;;
      "/system"*) system_size_after=$(get_available_size "system"); addToLog "- system_size ($pkg_size) spent=$((system_size_left-system_size_after))"; ;;
    esac
    addToLog "----------------------------------------------------------------------------"
  fi
}

find_install_type() {
  install_type="clean"
  for i in $(find /data -iname "runtime-permissions.xml" 2>/dev/null;); do
    if [ -e "$i" ]; then
      install_type="dirty"
      value=$(ReadConfigValue "WipeRuntimePermissions" "$nikgapps_config_file_name")
      [ -z "$value" ] && value=0
      addToLog "- runtime-permissions.xml found at $i with wipe permission $value"
      if [ "$value" = "1" ]; then
        rm -rf "$i"
      fi
    fi;
  done
  ui_print "- Install Type is $install_type"
}

find_log_directory() {
  value=$(ReadConfigValue "LogDirectory" "$nikgapps_config_file_name")
  addToLog "- LogDirectory=$value"
  [ "$value" = "default" ] && value="$nikGappsDir"
  [ -z "$value" ] && value="$nikGappsDir"
  nikgapps_log_dir="$value/nikgapps_logs"
}

find_zip_type() {
  addToLog "- Finding zip type"
  if [ "$(contains "-arm64-" "$actual_file_name")" = "true" ]; then
    zip_type="gapps"
  elif [ "$(contains "Debloater" "$actual_file_name")" = "true" ]; then
    zip_type="debloater"
  elif [ "$(contains "15" "$actual_file_name")" = "true" ] || [ "$(contains "YouTubeMusic" "$actual_file_name")" = "true" ]; then
    zip_type="addon_exclusive"
  elif [ "$(contains "Addon" "$actual_file_name")" = "true" ]; then
    zip_type="addon"
  elif [ "$(contains "package" "$actual_file_name")" = "true" ]; then
    zip_type="sideload"
  else
    zip_type="unknown"
  fi
  sideloading=false
  if [ "$(contains "package" "$ZIPNAME")" = "true" ]; then
    sideloading=true
  fi
  addToLog "- Zip Type is $zip_type"
  addToLog "- Sideloading is $sideloading"
}

get_file_prop() {
  grep -m1 "^$2=" "$1" | cut -d= -f2
}

get_prop() {
  local propdir propfile propval
  for propdir in /system /vendor /odm /product /system/product /system/system_ext /system_root /; do
    for propfile in build.prop default.prop; do
      test "$propval" && break 2 || propval="$(get_file_prop $propdir/$propfile "$1" 2>/dev/null)"
    done
  done
  addToLog "- propvalue $1 = $propval"
  # if propval is no longer empty output current result; otherwise try to use recovery's built-in getprop method
  [ -z "$propval" ] && propval=$(getprop "$1")
  addToLog "- Recovery getprop used $1=$propval"
  test "$propval" && echo "$propval" || echo ""
}

initialize_app_set() {
  value=1
  if [ -f "$nikgapps_config_file_name" ]; then
    value=$(ReadConfigValue "$1" "$nikgapps_config_file_name")
    if [ "$value" = "" ]; then
      value=1
    fi
  fi
  addToLog " "
  addToLog "- Inside InitializeAppSet, value=$value"
  if [ "$value" -eq 0 ]; then
    echo 0
  else
    addToLog "- Current_AppSet=$1"
    echo 1
  fi
}

install_the_package() {
  extn="zip"
  value=1
  pkgFile="$TMPDIR/$2.zip"
  pkgContent="pkgContent"
  if [ -f "$nikgapps_config_file_name" ]; then
    value=$(ReadConfigValue ">>$2" "$nikgapps_config_file_name")
    [ -z "$value" ] && value=$(ReadConfigValue "$2" "$nikgapps_config_file_name")
  fi
  addToLog " "
  addToLog "----------------------------------------------------------------------------"
  addToLog "- Working for $2"
  [ -z "$value" ] && value=1
  addToLog "- Config Value is $value"
  if [ "$value" -eq 0 ]; then
    ui_print "x Skipping $2"
  else
    unpack "AppSet/$1/$2.$extn" "$pkgFile"
    extract_file "$pkgFile" "installer.sh" "$TMPDIR/$pkgContent/installer.sh"
    chmod 755 "$TMPDIR/$pkgContent/installer.sh"
    # shellcheck source=src/installer.sh
    . "$TMPDIR/$pkgContent/installer.sh" "$value" "$nikgapps_config_file_name"
#    test $zip_type == "gapps" && copy_nikgapps_prop
  fi
}

install_file() {
  if [ "$mode" != "uninstall" ]; then
    # $1 will start with ___ which needs to be skipped so replacing it with blank value
    blank=""
    file_location=$(echo "$1" | sed "s/___/$blank/" | sed "s/___/\//g")
    # install_location is dynamic location where package would be installed (usually /system, /system/product)
    install_location="$install_partition/$file_location"
    # Make sure the directory exists, if not, copying the file would fail
    mkdir -p "$(dirname "$install_location")"
    set_perm 0 0 0755 "$(dirname "$install_location")"
    # unpacking of package
    addToLog "- Unzipping $pkgFile"
    addToLog "  -> copying $1"
    addToLog "  -> to $install_location"
    $BB unzip -o "$pkgFile" "$1" -p >"$install_location"
    # post unpack operations
    if [ -f "$install_location" ]; then
      addToLog "- File Successfully Written!"
      # It's important to set selinux policy
      case $install_location in
      *) ch_con system "$install_location" ;;
      esac
      set_perm 0 0 0644 "$install_location"
      # Addon stuff!
      case "$install_partition" in
          *"/product") installPath="product/$file_location" ;;
          *"/system_ext") installPath="system_ext/$file_location" ;;
          *) installPath="$file_location" ;;
      esac
      addToLog "$installPath"
      echo "install=$installPath" >>"$TMPDIR/addon/$packagePath"
    else
      addToLog "- Failed to write $install_location"
      abort "Installation Failed! Looks like Storage space is full!"
    fi
  fi
}

is_on_top_of_nikgapps() {
  nikgapps_present=false
  # shellcheck disable=SC2143
  if [ "$(grep 'allow-in-power-save package=\"com.mgoogle.android.gms\"' "$system"/etc/sysconfig/*.xml)" ] ||
        [ "$(grep 'allow-in-power-save package=\"com.mgoogle.android.gms\"' "$system"/product/etc/sysconfig/*.xml)" ]; then
    nikgapps_present=true
  fi
  addToLog "- Is on top of NikGapps: $nikgapps_present"
  if [ "$nikgapps_present" != "true" ]; then
    abort "This Addon can only be flashed on top of NikGapps"
  fi
}

# Check if the partition is mounted
is_mounted() {
  addToLog "- Checking if $1 is mounted"
  $BB mount | $BB grep -q " $1 ";
}

# Read the config file from (Thanks to xXx @xda)
ReadConfigValue() {
  value=$(sed -e '/^[[:blank:]]*#/d;s/[\t\n\r ]//g;/^$/d' "$2" | grep "^$1=" | cut -d'=' -f 2)
  echo "$value"
  return $?
}

RemoveAospAppsFromRom() {
  addToLog "- Removing AOSP App from Rom"
  if [ "$configValue" -eq 2 ]; then
    addToLog "- Not creating addon.d script for $*"
  else
    clean_recursive "$1"
    addToLog "- Creating addon.d script for $*"
    deletePath="$1"
    echo "delete=$deletePath" >>$TMPDIR/addon/"$deleteFilesPath"
  fi
}

RemoveFromRomWithGapps() {
  addToLog "- Removing From Rom with Gapps"
  clean_recursive "$1"
  addToLog "- Creating addon.d script for $*"
  deletePath="$1"
  echo "delete=$deletePath" >>$TMPDIR/addon/"$deleteFilesFromRomPath"
}

rmv() {
  addToLog "- Removing $1"
  rm -rf "$1"
}

set_perm() {
  chown "$1:$2" "$4"
  chmod "$3" "$4"
}

set_prop() {
  property="$1"
  value="$2"
  test -z "$3" && file_location="${install_partition}/build.prop" || file_location="$3"
  test ! -f "$file_location" && touch "$file_location" && set_perm 0 0 0600 "$file_location"
  addToLog "- Setting Property ${1} to ${2} in ${file_location}"
  if grep -q "${property}" "${file_location}"; then
    addToLog "- Updating ${property} to ${value} in ${file_location}"
    sed -i "s/\(${property}\)=.*/\1=${value}/g" "${file_location}"
  else
    addToLog "- Adding ${property} to ${value} in ${file_location}"
    echo "${property}=${value}" >>"${file_location}"
  fi
}

# show_progress <amount> <time>
show_progress() { echo "progress $1 $2" >>"$OUTFD"; }
# set_progress <amount>
set_progress() { echo "set_progress $1" >>"$OUTFD"; }

# Setting up mount point
setup_mountpoint() {
  addToLog "- Setting up mount point $1 before actual mount"
  test -L "$1" && $BB mv -f "$1" "${1}"_link;
  if [ ! -d "$1" ]; then
    rm -f "$1";
    mkdir -p "$1";
  fi;
}

restore_env() {
  $BOOTMODE && return 1;
  local dir;
  unset -f getprop;
  [ "$OLD_LD_PATH" ] && export LD_LIBRARY_PATH=$OLD_LD_PATH;
  [ "$OLD_LD_PRE" ] && export LD_PRELOAD=$OLD_LD_PRE;
  [ "$OLD_LD_CFG" ] && export LD_CONFIG_FILE=$OLD_LD_CFG;
  unset OLD_LD_PATH OLD_LD_PRE OLD_LD_CFG;
  umount_all;
  [ -L /etc_link ] && $BB rm -rf /etc/*;
  (for dir in /apex /system /system_root /etc; do
    if [ -L "${dir}_link" ]; then
      rmdir $dir;
      $BB mv -f ${dir}_link $dir;
    fi;
  done;
  $BB umount -l /dev/random) 2>/dev/null;
}

uninstall_file() {
  addToLog "- Inside UninstallFile, mode is $mode"
  if [ "$mode" = "uninstall" ]; then
    # $1 will start with ___ which needs to be skipped so replacing it with blank value
    blank=""
    file_location=$(echo "$1" | sed "s/___/$blank/" | sed "s/___/\//g")
    # install_location is dynamic location where package would be installed (usually /system, /system/product)
    install_location="$install_partition/$file_location"
    # Remove the file
    addToLog "- Removing the file $install_location"
    rm -rf "$install_location"
    addon_file=$package_title".sh"
    # Removing the addon sh so it doesn't get backed up and restored
    addToLog "- Removing $addon_file"
    rm -rf "/system/addon.d/nikgapps/$addon_file"
    # Removing the updates and residue
    [ -n "$package_name" ] && rm -rf "/data/data/$package_name" && rm -rf "/data/app/$package_name*" && rm -rf "/data/app/*/$package_name*"
  fi
}