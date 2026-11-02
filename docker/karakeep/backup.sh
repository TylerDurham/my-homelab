#!/bin/sh
BACKUP_FILE="karakeep-backup"
docker-compose stop
docker cp karakeep_web_1:/tmp/karakeep-backup.tar.gz ./karakeep-backup-$(date +%F).tar.gz
docker-compose start
#tar czf./karakeep-git-backup$(data +%F).tar.gz -C ./data/git/repositories/ . 
