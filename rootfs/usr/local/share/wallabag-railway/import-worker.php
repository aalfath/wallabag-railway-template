<?php
// One Redis import worker for every wallabag import queue.
// wallabag's own `wallabag:import:redis-worker <service>` serves one queue per
// process (14 processes for all importers). This loop boots the app once and
// serves all queues with the same consumers. It exits after 1000 jobs, or when
// Doctrine's entity manager is closed after an error; s6 then restarts it.

set_time_limit(0);
require '/var/www/wallabag/vendor/autoload.php';

$kernel = new AppKernel('prod', false);
$kernel->boot();
$container = $kernel->getContainer();

$services = ['pocket', 'pocket_csv', 'pocket_html', 'readability', 'instapaper', 'pinboard', 'delicious',
    'omnivore', 'wallabag_v1', 'wallabag_v2', 'elcurator', 'firefox', 'chrome', 'shaarli'];
$queues = [];
foreach ($services as $service) {
    if ($container->has('wallabag_import.queue.redis.' . $service) && $container->has('wallabag_import.consumer.redis.' . $service)) {
        $queues['wallabag.import.' . $service] = $service;
    }
}

$redis = $container->get(Predis\Client::class);
echo sprintf("[import-worker] watching %d import queues\n", count($queues));

$done = 0;
while (true) {
    $item = $redis->brpop(array_keys($queues), 30);
    if (!$item) {
        continue;
    }
    [$queue, $job] = $item;
    $service = $queues[$queue];
    try {
        if (!$container->get('wallabag_import.consumer.redis.' . $service)->manage($job)) {
            $redis->lpush($queue . '-failed', [$job]);
        }
    } catch (\Throwable $e) {
        fwrite(STDERR, sprintf("[import-worker] %s: %s\n", $service, $e->getMessage()));
        $redis->lpush($queue . '-error', [$job]);
    }
    ++$done;
    if ($done >= 1000 || !$container->get('doctrine')->getManager()->isOpen()) {
        echo sprintf("[import-worker] recycling after %d jobs\n", $done);
        exit(0);
    }
}
