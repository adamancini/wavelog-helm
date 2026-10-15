<?php
// Wavelog Helm chart bootstrap. Runs as an init container before Apache starts.
// Phases are plain functions; main() runs them in order.
// Every PHP value written into a config file goes through var_export().

const WL_DEFAULT_KEY = 'flossie1234555541';
const WL_APP_DIR = '/var/www/html';
const WL_TEMPLATE_DIR = WL_APP_DIR . '/install/config';
const WL_INSTALL_DIR = WL_APP_DIR . '/install';

function fail(string $reason): void
{
    fwrite(STDERR, 'bootstrap: ' . str_replace(["\r", "\n"], ' ', $reason) . "\n");
    exit(1);
}

function info(string $message): void
{
    fwrite(STDOUT, 'bootstrap: ' . $message . "\n");
}

// Upstream's installer class logs through CodeIgniter's log_message(); forward
// its errors to stderr so a failed schema install says why.
function log_message(string $level, string $message): void
{
    if ($level === 'error') {
        fwrite(STDERR, 'bootstrap: installer: ' . str_replace(["\r", "\n"], ' ', $message) . "\n");
    }
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
// The template's placeholders must match $values exactly. The check runs on the
// template, before substitution, so values that look like placeholders (e.g.
// '%b%') are fine; strtr() substitutes in one pass and never rescans a value.
function fill_template(string $tpl, array $values): string
{
    preg_match_all("/'%([A-Za-z_]+)%'/", $tpl, $m);
    $found = array_unique($m[1]);
    foreach (array_diff(array_keys($values), $found) as $name) {
        fail("placeholder '%$name%' not found in template");
    }
    foreach (array_diff($found, array_keys($values)) as $name) {
        fail("unfilled placeholder '%$name%' in template");
    }
    $pairs = [];
    foreach ($values as $name => $value) {
        $pairs["'%" . $name . "%'"] = var_export($value, true);
    }
    return strtr($tpl, $pairs);
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

function db(): mysqli
{
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
    $db->real_connect(
        env('WL_DB_HOST'),
        env('WL_DB_USER'),
        env('WL_DB_PASSWORD'),
        env('WL_DB_NAME'),
        (int) env('WL_DB_PORT', '3306')
    );
    $db->set_charset('utf8mb4');
    return $db;
}

// Retry every 3 s until WL_DB_WAIT_SECONDS. Wrong credentials fail at once.
function wait_for_db(): mysqli
{
    $limit = (int) env('WL_DB_WAIT_SECONDS', '300');
    $deadline = time() + $limit;
    while (true) {
        try {
            return db();
        } catch (mysqli_sql_exception $e) {
            if (in_array($e->getCode(), [1044, 1045], true)) {
                fail('database login failed: ' . $e->getMessage());
            }
            if (time() >= $deadline) {
                fail("database not reachable after {$limit}s: " . $e->getMessage());
            }
            info('waiting for database (' . $e->getMessage() . ')');
            sleep(3);
        }
    }
}

function scalar(mysqli $db, string $sql): int
{
    return (int) $db->query($sql)->fetch_row()[0];
}

// installed: users has at least one row; empty: no tables; anything else: partial.
function install_state(mysqli $db): string
{
    $tables = scalar($db, 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()');
    if ($tables === 0) {
        return 'empty';
    }
    $hasUsers = scalar($db, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'users'");
    if ($hasUsers === 1 && scalar($db, 'SELECT COUNT(*) FROM users') >= 1) {
        return 'installed';
    }
    return 'partial';
}

// Runs upstream's own installer class (install/includes/core/database_class.php,
// Database::create_tables) so install.sql gets exactly upstream's escaping and
// password_hash substitution. Only call on an empty schema: install.sql drops
// and recreates every table.
function install_schema(): void
{
    $username = env('WL_ADMIN_USERNAME');
    $password = env('WL_ADMIN_PASSWORD');
    if ($username === '' || $password === '') {
        fail('admin username and password must not be empty');
    }
    require_once WL_INSTALL_DIR . '/includes/core/database_class.php';
    // create_tables() connects without a port argument and reads
    // 'assets/install.sql' relative to the installer directory.
    ini_set('mysqli.default_port', env('WL_DB_PORT', '3306'));
    if (!chdir(WL_INSTALL_DIR)) {
        fail('cannot enter ' . WL_INSTALL_DIR);
    }
    $ok = (new Database())->create_tables([
        'db_hostname' => env('WL_DB_HOST'),
        'db_username' => env('WL_DB_USER'),
        'db_password' => env('WL_DB_PASSWORD'),
        'db_name' => env('WL_DB_NAME'),
        'username' => $username,
        'password' => $password,
        'user_email' => env('WL_ADMIN_EMAIL'),
        'callsign' => env('WL_ADMIN_CALLSIGN'),
        'userlocator' => env('WL_ADMIN_LOCATOR'),
        'firstname' => env('WL_ADMIN_FIRSTNAME'),
        'lastname' => env('WL_ADMIN_LASTNAME'),
        'timezone' => env('WL_ADMIN_TIMEZONE', '0'),
        'dxcc' => env('WL_ADMIN_DXCC', '0'),
        'city' => env('WL_ADMIN_CITY'),
        'userlanguage' => env('WL_ADMIN_LANGUAGE', 'english'),
    ]);
    chdir('/');
    if (!$ok) {
        fail('schema install failed');
    }
}

// CodeIgniter accepts CLI requests, so the Migrate controller runs directly:
// `php index.php migrate` (CI_ENV=docker selects the rendered config). It
// prints {"status":"success","version":N}. Verified against Wavelog 3.2.4; the
// php -S fallback was not needed.
function run_migrations(): void
{
    $env = getenv();
    $env['CI_ENV'] = 'docker';
    $proc = proc_open(
        ['php', WL_APP_DIR . '/index.php', 'migrate'],
        [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]],
        $pipes,
        WL_APP_DIR,
        $env
    );
    if (!is_resource($proc)) {
        fail('cannot start migrations');
    }
    $out = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $rc = proc_close($proc);
    if ($rc !== 0 || !preg_match('/"status"\s*:\s*"success"/', $out)) {
        fail("migrations failed (exit $rc): " . substr(trim(strip_tags($out)), 0, 500));
    }
    $v = preg_match('/"version"\s*:\s*"?(\d+)/', $out, $m) ? $m[1] : '?';
    info("migrations at version $v");
}

function main(): int
{
    // Never print a stack trace: its arguments can include passwords.
    set_exception_handler(function (Throwable $e): void {
        fail('unexpected error: ' . $e->getMessage());
    });

    render_config();
    info('config rendered');

    $db = wait_for_db();
    $state = install_state($db);
    info("database state: $state");
    if ($state === 'partial') {
        fail('partial install detected; restore from backup or drop the schema');
    }
    if ($state === 'empty') {
        install_schema();
        if (install_state($db) !== 'installed') {
            fail('schema install did not create the admin user');
        }
        info('schema installed');
    }
    $db->close();

    run_migrations();
    return 0;
}

// Tests define WL_BOOTSTRAP_NO_MAIN to include the functions without running.
if (!defined('WL_BOOTSTRAP_NO_MAIN')) {
    exit(main());
}
