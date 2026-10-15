<?php
// Wavelog Helm chart bootstrap. Runs as an init container before Apache starts.
// Phases are plain functions; main() runs them in order.
// Every PHP value written into a config file goes through var_export().

const WL_DEFAULT_KEY = 'flossie1234555541';
const WL_TEMPLATE_DIR = '/var/www/html/install/config';

function fail(string $reason): void
{
    fwrite(STDERR, 'bootstrap: ' . str_replace(["\r", "\n"], ' ', $reason) . "\n");
    exit(1);
}

function env(string $name, string $default = ''): string
{
    $v = getenv($name);
    return ($v === false) ? $default : $v;
}

function read_template(string $name): string
{
    $path = WL_TEMPLATE_DIR . '/' . $name;
    $s = @file_get_contents($path);
    if ($s === false) {
        fail("cannot read template $path");
    }
    return $s;
}

// Replace each quoted placeholder ('%name%', quotes included) with a PHP literal.
function fill_template(string $tpl, array $values): string
{
    foreach ($values as $name => $value) {
        $token = "'%" . $name . "%'";
        if (strpos($tpl, $token) === false) {
            fail("placeholder $token not found in template");
        }
        $tpl = str_replace($token, var_export($value, true), $tpl);
    }
    if (preg_match("/'%[A-Za-z_]+%'/", $tpl, $m)) {
        fail("unfilled placeholder {$m[0]} in template");
    }
    return $tpl;
}

// Write atomically with mode 0640 so Apache (group www-data) can read it.
function write_file(string $dir, string $name, string $content): void
{
    if (!is_dir($dir) || !is_writable($dir)) {
        fail("config directory $dir is not writable");
    }
    $tmp = $dir . '/.' . $name . '.tmp';
    $old = umask(0027);
    $ok = file_put_contents($tmp, $content) !== false;
    umask($old);
    if (!$ok || !chmod($tmp, 0640) || !rename($tmp, $dir . '/' . $name)) {
        @unlink($tmp);
        fail("cannot write $dir/$name");
    }
}

function render_config(): void
{
    $dir = env('WL_CONFIG_DIR');
    if ($dir === '') {
        fail('WL_CONFIG_DIR is not set');
    }
    $key = env('WL_ENCRYPTION_KEY');
    if ($key === '' || $key === WL_DEFAULT_KEY) {
        fail('encryption key missing or default');
    }

    $callbook = env('WL_CALLBOOK', 'hamqth');
    $values = [
        'directory' => '',
        'callbook' => $callbook,
        'baselocator' => env('WL_LOCATOR'),
        'websiteurl' => env('WL_BASE_URL'),
        'log_threshold' => (int) env('WL_LOG_THRESHOLD', '0'),
        'encryptionkey' => $key,
        'qrzcall_token' => ($callbook === 'qrzcall') ? env('WL_QRZCALL_TOKEN') : '',
    ];
    foreach (['qrz', 'hamqth', 'qrzcq', 'qrzru'] as $provider) {
        $on = ($callbook === $provider);
        $values[$provider . '_username'] = $on ? env('WL_CALLBOOK_USERNAME') : '';
        $values[$provider . '_password'] = $on ? env('WL_CALLBOOK_PASSWORD') : '';
    }
    $config = fill_template(read_template('config.php'), $values);

    if (env('WL_AUTH_MODE', 'local') === 'header') {
        $flag = '$config[\'auth_header_enable\'] = false;';
        if (strpos($config, $flag) === false) {
            fail('auth_header_enable not found in config template');
        }
        $config = str_replace($flag, '$config[\'auth_header_enable\'] = true;', $config);
    }

    $extra = json_decode(env('WL_EXTRA_CONFIG_JSON', '{}') ?: '{}', true);
    if (!is_array($extra)) {
        fail('WL_EXTRA_CONFIG_JSON must be a JSON object');
    }
    if ($extra) {
        $config = rtrim($config) . "\n\n// Added by the Helm chart (config.extra)\n";
        foreach ($extra as $k => $v) {
            $config .= '$config[' . var_export((string) $k, true) . '] = ' . var_export($v, true) . ";\n";
        }
    }

    // CodeIgniter's mysqli driver takes the port from 'port', not 'host:port'.
    $db = read_template('database.php');
    $hostLine = "'hostname' => '%HOSTNAME%',";
    if (strpos($db, $hostLine) === false) {
        fail('hostname placeholder not found in database template');
    }
    $db = str_replace($hostLine, $hostLine . "\n\t'port' => " . var_export((int) env('WL_DB_PORT', '3306'), true) . ',', $db);
    $db = fill_template($db, [
        'HOSTNAME' => env('WL_DB_HOST'),
        'USERNAME' => env('WL_DB_USER'),
        'PASSWORD' => env('WL_DB_PASSWORD'),
        'DATABASE' => env('WL_DB_NAME'),
    ]);

    write_file($dir, 'config.php', $config);
    write_file($dir, 'database.php', $db);
}

function main(): int
{
    render_config();
    return 0;
}

exit(main());
