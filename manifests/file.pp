# #### Overview:
#
# Define resource to retrieve files to staging directories. It is
# intentionally not replacing files, as these intend to be large binaries
# that are versioned.
#
# #### Notes:
#
#   If you specify a different staging location, please manage the file
#   resource as necessary.
#
define staging::file (
  $source,              #: the source file location, supports local files, puppet:///, http://, https://, ftp://, s3://
  $target      = undef, #: the target file location, if unspecified ${staging::path}/${subdir}/${name}
  $username    = undef, #: https or ftp username
  $certificate = undef, #: https certificate file
  $password    = undef, #: https or ftp user password or https certificate password
  $environment = undef, #: environment variable for settings such as http_proxy, https_proxy, of ftp_proxy
  $timeout     = undef, #: the time to wait for the file transfer to complete
  $curl_option = undef, #: options to pass to curl
  $wget_option = undef, #: options to pass to wget
  $tries       = undef, #: amount of retries for the file transfer when non transient connection errors exist
  $try_sleep   = undef, #: time to wait between retries for the file transfer
  $owner       = undef, #: file owner in the local filesystem for the target
  $group       = undef, #: file group in the local filesystem for the target
  $mode        = undef, #: file mode in the local filesystem for the target
  $subdir      = $caller_module_name,
  $novalidate  = false #: Whether to bypass https validation - powershell only
) {

  include staging

  $quoted_source = shellquote($source)

  if $target {
    $target_file = $target
    $staging_dir = staging_parse($target, 'parent')
  } else {
    $staging_dir = regsubst("${staging::_path}/${subdir}", '/$', '') # Strip off trailing slashes
    $target_file = "${staging_dir}/${name}"

    if ! defined(File[$staging_dir]) {
      file { $staging_dir:
        ensure => 'directory',
        owner  => $staging::owner,
        group  => $staging::group,
        mode   => $staging::mode,
      }
    }
  }

  Exec {
    path        => $staging::exec_path,
    environment => $environment,
    cwd         => $staging_dir,
    creates     => $target_file,
    timeout     => $timeout,
    try_sleep   => $try_sleep,
    tries       => $tries,
    logoutput   => on_failure,
  }

  case $::staging_http_get {
    'curl', default: {
      $quoted_credentials = shellquote("${username}:${password}")
      $http_get           = "curl ${curl_option} -f -L -o ${target_file} ${quoted_source}"
      $http_get_passwd    = "curl ${curl_option} -f -L -o ${target_file} -u ${quoted_credentials} ${quoted_source}"
      $http_get_cert      = "curl ${curl_option} -f -L -o ${target_file} -E ${certificate}:${password} ${quoted_source}"
      $ftp_get            = "curl ${curl_option} -o ${target_file} ${quoted_source}"
      $ftp_get_passwd     = "curl ${curl_option} -o ${target_file} -u ${username}:${password} ${quoted_source}"
    }
    'wget': {
      $quoted_password = shellquote($password)
      $http_get        = "wget ${wget_option} -O ${target_file} ${quoted_source}"
      $http_get_passwd = "wget ${wget_option} -O ${target_file} --user=${username} --password=${quoted_password} ${quoted_source}"
      $http_get_cert   = "wget ${wget_option} -O ${target_file} --user=${username} --certificate=${certificate} ${quoted_source}"
      $ftp_get         = $http_get
      $ftp_get_passwd  = $http_get_passwd
    }
    'powershell':{
      $http_get        = "powershell.exe -Command \"\$wc = New-Object System.Net.WebClient;\$wc.DownloadFile('${source}','${target_file}')\""
      $http_get_passwd = "powershell.exe -Command \"\$wc = New-Object System.Net.WebClient;\$wc.Credentials = New-Object System.Net.NetworkCredential('${username}','${password}');\$wc.DownloadFile('${source}','${target_file}')\""
      $http_get_noval  = "powershell.exe -Command \"[System.Net.ServicePointManager]::ServerCertificateValidationCallback={\$true};\$wc = New-Object System.Net.WebClient;\$wc.DownloadFile('${source}','${target_file}');[System.Net.ServicePointManager]::ServerCertificateValidationCallback=\$null\""
      $ftp_get         = $http_get
      $ftp_get_passwd  = $http_get_passwd
    }
  }

  case $source {
    /^\//: {
      file { $target_file:
        source  => $source,
        owner   => $owner,
        group   => $group,
        mode    => $mode,
        replace => false,
      }
    }
    /^[A-Za-z]:/: {
      if versioncmp($::puppetversion, '3.4.0') >= 0 {
        file { $target_file:
          source             => $source,
          owner              => $owner,
          group              => $group,
          mode               => $mode,
          replace            => false,
          source_permissions => ignore,
        }
      } else {
        file { $target_file:
          source  => $source,
          owner   => $owner,
          group   => $group,
          mode    => $mode,
          replace => false,
        }
      }
    }
    /^file:\/\//: {
      file { $target_file:
        source  => $source,
        owner   => $owner,
        group   => $group,
        mode    => $mode,
        replace => false,
      }
    }
    /^puppet:\/\//: {
      file { $target_file:
        source  => $source,
        owner   => $owner,
        group   => $group,
        mode    => $mode,
        replace => false,
      }
    }
    /^http:\/\//: {
      if $username { $command = $http_get_passwd }
      else         { $command = $http_get        }
      exec { $target_file:
        command   => $command,
      }
    }
    /^https:\/\//: {
      if $username       { $command = $http_get_passwd }
      elsif $certificate { $command = $http_get_cert   }
      elsif $novalidate  { $command = $http_get_noval  }
      else               { $command = $http_get        }
      exec { $target_file:
        command => $command,
      }
    }
    /^ftp:\/\//: {
      if $username       { $command = $ftp_get_passwd }
      else               { $command = $ftp_get        }
      exec { $target_file:
        command     => $command,
      }
    }
    /^s3:\/\//: {
      $command = "aws s3 cp ${source} ${target_file}"
      exec { $target_file:
        command   => $command,
      }
    }
    default: {
      fail("staging::file: do not recognize source ${source}.")
    }
  }

  if $source =~ /^(?:https?|ftp|s3):\/\// {
    file { $target_file:
      ensure  => file,
      owner   => $owner,
      group   => $group,
      mode    => $mode,
      require => Exec[$target_file],
    }
  }

}
