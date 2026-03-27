return {
    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier  = "com.tiagsspace.lightroom-wp-export",
    LrPluginName         = "WordPress Upload",
    LrPluginInfoUrl      = "https://github.com/tiagogon/lightroom-wp-export",

    LrPluginInfoProvider = "PluginInfoProvider.lua",

    LrExportServiceProvider = {
        title = "WordPress Upload",
        file  = "ExportServiceProvider.lua",
    },

    VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
