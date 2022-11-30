# Ansible playbook for deployment of PostgreSQL/PostGIS/TimescaleDB Patroni/Consul cluster with WAL-G backups in Docker Compose

Плейбук Ansible для развёртывания кластера СУБД Postgres + PostGIS + TimescaleDB под управлением Patroni и Consul с резервным копированием посредством WAL-G в Docker Compose.

## Содержание
1 [Введение](#introduction)  
2 [Подготовка](#preparation)  
3 [Новое развёртывание](#new_deployment)  
4 [Управление существующей установкой](#existing_deployment)  
5 [Резервное копирование и восстановление](#backups)  
5.1 [Непрерывное автоматическое резервное копирование в S3](#continuous_backup_s3)  
5.2 [Резервное копирование по требованию в S3](#on_demand_backup_s3)  
5.3 [Восстановление из резервной копии S3](#restore_s3)  
5.4 [Проверка данных после восстановления](#restore_check)  
6 [Добавление нового узла в кластер Patroni](#new_node)  
6.1 [Добавление нового узла в кластер Patroni с репликацией данных с ведущего узла кластера](#new_node_master_replication)  
6.2 [Добавление нового узла в кластер Patroni с загрузкой данных из S3](#new_node_s3)  
7 [Миграция одиночной установки PostgreSQL в кластер Patroni](#migrate_from_single)  
7.1 [Миграция одиночной установки PostgreSQL в кластер Patroni через резервную копию данных](#migrate_from_single_s3)  
7.2 [Миграция одиночной установки PostgreSQL в кластер Patroni с обновлением базы данных](#migrate_from_single_upgrade)  
8 [Возможные проблемы](#issues)  
8.1 [При первом запуске кластера СУБД после установки не запускается Postgres](#postgres_not_starting)  
8.2 [После перезапуска узла кластера СУБД состояние узла кластера - start failed](#postgres_start_failed)  
9 [Дополнительная информация](#info)  


## 1 Введение <a name="introduction"/>
Docker-образ, содержащий программное обеспечение, необходимое для работы кластера PostgreSQL + PostGIS + TimescaleDB под управлением Patroni/Consul, собирается посредством GitLab CI/CD и хранится в репозитории образов GitLab container registry. Конфигурация GitLab CI/CD описывается в файле _.gitlab-ci.yml_.

Развёртывание кластера Patroni/Consul осуществляется автоматизированно посредством системы управления конфигурациями Ansible.

Кластер Patroni/Consul может состоять из одного или более узлов. При необходимости добавления реплик в существующий кластер достаточно добавить новые хосты в файл _ansible/inventory.ini_ и повторно запустить развёртывание Consul и Patroni при помощи Ansible. Данная процедура подробно изложена в разделе **6 Добавление нового узла в кластер СУБД**.  

Резервное копирование выполняется непрерывно и автоматически на текущем ведущем узле кластера СУБД посредством сжатия файлов журналов транзакций WAL и загрузки их в хранилище данных S3 при помощи утилиты WAL-G. Кроме того, один раз в сутки ночью выполняется создание полной копии данных СУБД в хранилище данных S3 при помощи утилиты WAL-G. Резервное копирование и восстановление подробно описано в разделе **5 Резервное копирование и восстановление**.


## 2 Подготовка <a name="preparation"/>

1. На целевых узлах разрешить беспарольное использование команды **sudo** для пользователя **ansible_user**.
2. Сгенерировать конфигурационные файлы (**ansible/inventory.ini** и **ansible/group_vars/all.yml**), выполнив команду:
```shell
ansible-playbook 0_generate_configs.yml
```
 - Определить, на каких узлах должны быть развёрнуты серверы Consul и на каких узлах должны быть развёрнуты клиенты Consul.  
 Серверы Consul предполагается устанавливать на узлы кластера Patroni совместно с СУБД PostgreSQL. Для обеспечения отказоустойчивости число серверов Consul было не менее трёх. Клиенты Consul должны быть развёрнуты на узлах, где выполняется приложение-клиент СУБД.
 - Следует добавить серверы и клиенты Consul в группы **consul** и **consul_client**, соответственно.
 - Отредактировать **ansible/inventory.ini**, указав корректные адреса IP или DNS и имена пользователей для хостов развёртывания.  
 При этом, следует указывать публичные адреса хостов развёртывания в значении параметра **ansible_host**, а приватные адреса хостов развёртывания -- в значении параметра **lan_host**, например:  
```shell
[all]
pg1 ansible_host=123.234.56.78 lan_host=10.1.0.13 ansible_user=ubuntu
```
 Если при развёртывании доступ к хостам осуществляется по приватным адресам, следует указывать приватные адреса хостов в значении обоих параметров, например:  
```shell
[all]
pg1 ansible_host=10.1.0.13 lan_host=10.1.0.13 ansible_user=ubuntu
```
 - Перед настройкой параметров резервного копирования необходимо создать бакет в хранилище данных S3 и ключи для доступа к бакету (**s3_access_key** и **s3_secret_key**).
 - Также необходимо подготовить параметры доступа к Docker (container) registry, необходимые для загрузки образа кластера Patroni/Consul, которые задаются в веб-интерфейсе GitLab. В частности, имя пользователя **docker_registry_username** и пароль **docker_registry_username** на доступ к Docker registry задаются в разделе **Settings->Repository->Deploy tokens** репозитория GitLab. Токен должен иметь полномочия **read_registry**.
 - Отредактировать **ansible/group_vars/all.yml**, указав корректные параметры развёртывания.
 - Для генерации значения параметра **consul_encrypt** может быть использована команда `head -c${1:-32} /dev/urandom | base64`.  
 - При задании значений параметров **postgres_replicator_password** и **postgres_superuser_password** следует использовать пароли достаточной сложности.
3. Если в целевой сети развёртывания отсутствует служба DNS, то для того, чтобы узлы кластера могли связываться по именам,
следует сгенерировать файлы **/etc/hosts** на целевых машинах, выполнив команды:
```shell
cd ./ansible
ansible-playbook -i inventory.ini 1_populate_hosts.yml
```


## 3 Новое развёртывание <a name="new_deployment"/>

1. Выполнить последовательность команд:
```shell
cd ./ansible
ansible-playbook -i inventory.ini 3_install_docker.yml
```
2. Для развёртывания кластера Consul выполнить команду
```shell
ansible-playbook -i inventory.ini 4_install_consul.yml
```
3. Для развёртывания кластера Patroni выполнить команду
```shell
ansible-playbook -i inventory.ini 5_install_patroni.yml
```


## 4 Управление существующей установкой <a name="existing_deployment"/>
1. Запросить информацию о состоянии кластера Patroni можно выполнив на любом узле кластера команду

```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml list
+--------+-------------+---------+---------+----+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+ Cluster: patroni-cluster (7096851968026091552) -----------+
| pg1    | 10.1.0.13   | Replica | running |  1 |         0 |
| pg2    | 10.1.0.32   | Leader  | running |  2 |           |
| pg3    | 10.1.0.9    | Replica | running |  2 |         0 |
+--------+-------------+---------+---------+----+-----------+
```

2. На узлах кластера Patroni настроено разрешение имён узлов кластера СУБД
посредством сервера DNS кластера Consul. Текущий ведущий (leader, master) узел кластера СУБД всегда доступен по имени **master.patroni-cluster.service.consul**. Узлы-реплики СУБД доступны по имени **replica.patroni-cluster.service.consul**. Если число реплик больше одной, то при запросе к серверу DNS Consul их IP-адреса возвращаются по-очереди в режиме round-robin.
3. Для настройки разрешения имён узлов кластера СУБД посредством сервера DNS Consul на узлах сети, не входящих в состав кластера СУБД, следует установить клиенты Consul на означенные узлы сети. Для этого следует перечислить имена означенных узлов в разделе **[consul_client]** файла _ansible/inventory.ini_ и выполнить развёртывание кластера Consul при помощи команды
```shell
ansible-playbook -i inventory.ini 4_install_consul.yml
```
4. Настройка параметров СУБД PostgreSQL осуществляется в разделе **bootstrap.dcs.postgresql.parameters** файла _ansible/roles/install_patroni/templates/patroni.yml.j2_.
Для применения изменений параметров СУБД PostgreSQL необходимо перезапустить развёртывание кластера Patroni, выполнив команду
```shell
ansible-playbook -i inventory.ini 5_install_patroni.yml
```
См. также п. 3 в разделе **9 Дополнительная информация -> Patroni**.  
5. Переключение ведущего узла кластера может быть выполнено при помощи команды

```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml switchover
Master [pg2]:
Candidate ['pg3'] []: pg3
When should the switchover take place (e.g. 2022-05-16T17:35 )  [now]: now
Current cluster topology
+--------+-------------+---------+---------+----+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+ Cluster: patroni-cluster (7096851968026091552) -----------+
| pg2    | 10.1.0.32   | Leader  | running | 36 |           |
| pg3    | 10.1.0.9    | Replica | running | 36 |         0 |
+--------+-------------+---------+---------+----+-----------+
Are you sure you want to switchover cluster patroni-cluster, demoting current master pg2? [y/N]: y
```


## 5 Резервное копирование и восстановление <a name="backups"/>

### 5.1 Непрерывное автоматическое резервное копирование в S3 <a name="continuous_backup_s3"/>
Резервное копирование выполяется неперывно и автоматически на текущем **ведущем** узле кластера СУБД посредством сжатия файлов журналов транзакций WAL и загрузки их в хранилище данных S3. Кроме того, один раз в сутки ночью выполняется создание полной копии данных СУБД в хранилище данных S3.  

Резервные копии старше заданного возраста автоматически удаляются после создания полной копии. Срок хранения резервных копий задаётся параметром **postgres_backup_keep_full** в файле _ansible/group_vars/all.yml_.  

Восстановление данных производится из полной копии данных и из файлов журналов транзакций WAL, накопленных с момента создания полной копии данных до заданного момента времени, на который требуется восстановление данных.  

Расписание создания полных копий данных СУБД задаётся на узлах кластера СУБД в файле _/var/spool/cron/crontabs/root_. Для изменения расписания резервного копирования следует переопределить нижеперечисленные параметры в файле
_ansible/group_vars/all.yml_ и повторить развёртывание кластера Patroni:
```yaml
postgres_backup_cron_day: "*"
postgres_backup_cron_hour: "5"
postgres_backup_cron_minute: "20"
```
Резервные копии данных СУБД загружаются в хранилище данных S3, параметры доступа к которому задаются на узлах кластера СУБД в файле _/opt/patroni/walg.json_. Для изменения параметров доступа к хранилищу данных S3 следует отредактировать нижеперечисленные параметры в файле _ansible/group_vars/all.yml_ и повторить развёртывание кластера Patroni:
```yaml
s3_access_key_ro: "AKIAKIAKI1"
s3_secret_key_ro: "secret123"
s3_access_key_rw: "AKIAKIAKI2"
s3_secret_key_rw: "secret456"
s3_region: "ru-central1"
s3_endpoint: "https://storage.yandexcloud.net/"
s3_backup_path: "s3://backups/postgres/"
s3_path_style: "true"
```

Журнал сообщений полного резервного копирования отправляется в системную службу протоколирования **syslog** с тегом **wal-g**. Пример записей журнала резервного копирования:
```shell
$ grep 'wal-g' /var/log/syslog
Jun  9 06:16:57 pg2 wal-g: INFO: 2022/06/09 06:16:57.747999 Calling pg_start_backup()#015
Jun  9 06:16:57 pg2 wal-g: INFO: 2022/06/09 06:16:57.820750 Starting a new tar bundle#015
Jun  9 06:16:57 pg2 wal-g: INFO: 2022/06/09 06:16:57.820832 Walking ...#015
Jun  9 06:16:57 pg2 wal-g: INFO: 2022/06/09 06:16:57.821122 Starting part 1 ...#015
...
```

### 5.2 Резервное копирование по требованию в S3 <a name="on_demand_backup_s3"/>
1. Если активность записи на ведущем узле кластера СУБД невысока, то чтобы в архив
попало как можно больше последних данных, перед созданием резервной копии данных СУБД имеет смысл выполнить переключение сегмента журнала WAL при помощи команды
```shell
docker exec -it patroni psql -c 'select pg_switch_wal();'
```
2. Затем выполнить архивирование и загрузку данных СУБД в хранилище S3 при помощи команды
```shell
docker exec -it patroni wal-g --config /var/lib/postgresql/walg.json backup-push /var/lib/postgresql/data
```
3. После чего выполнить удаление устаревших архивов и журналов WAL при помощи команды
```shell
docker exec -it patroni wal-g --config /var/lib/postgresql/walg.json delete retain FULL 7
```
Дополнительная информация о команде `wal-g backup-push`: [https://github.com/wal-g/wal-g/blob/master/docs/PostgreSQL.md#backup-push](https://github.com/wal-g/wal-g/blob/master/docs/PostgreSQL.md#backup-push).  
Дополнительная информация о команде `wal-g delete`: [https://github.com/wal-g/wal-g#delete](https://github.com/wal-g/wal-g#delete).  


### 5.3 Восстановление из резервной копии в S3 <a name="restore_s3"/>
1. Получить перечень полных резервных копий данных СУБД можно посредством выполнения на любом узле кластера Patroni команды
```shell
docker exec patroni wal-g --config /var/lib/postgresql/walg.json backup-list
```
2. Получить перечень сегментов журналов WAL с группировкой по таймлайнам можно посредством выполнения на любом узле кластера Patroni команды
```shell
docker exec -it patroni wal-g --config /var/lib/postgresql/walg.json wal-show
```
3. Если необходим возврат к состоянию данных СУБД на определённый момент времени (PITR), то следует задать требуемое время в значении параметра **patroni_recovery_target_time** в файле _ansible/group_vars/all.yml_, например:
```yaml
patroni_recovery_target_time: "2022-05-17 10:00:00.000"
```
Если требуется восстановление последнего состояния данных СУБД, параметр **patroni_recovery_target_time** следует оставить пустым. При необходимости восстановления данных из таймлайна, отличного от последнего, следует также задать параметр **patroni_recovery_target_timeline** в файле _ansible/group_vars/all.yml_.  

4. Установить параметр **patroni_bootstrap_method** в файле _ansible/group_vars/all.yml_ в значение **walg**:
```yaml
patroni_bootstrap_method: "walg"
```
5. Отключить автоматический запуск службы Patroni на всех узлах кластера Patroni, выполнив на узле управления Ansible команду
```shell
ansible all -i inventory.ini --become -a "systemctl disable patroni-docker"
```
6. Остановить службу Patroni сначала на всех узлах-репликах, затем на ведущем узле кластера Patroni, выполнив на вышеозначенных узлах команды
```shell
systemctl stop patroni-docker
docker rm patroni
```
7. Удалить кластер Patroni из хранилища данных Consul, выполнив на любом узле кластера Patroni команду

```shell
$ docker run --rm -it -v {{ postgres_volume_name }}:/var/lib/postgresql \
  -v /opt/patroni/patroni.yml:/var/lib/postgresql/patroni.yml patroni \
  patronictl -c /var/lib/postgresql/patroni.yml remove patroni-cluster
+--------+------+------+-------+----+-----------+
| Member | Host | Role | State | TL | Lag in MB |
+ Cluster: patroni-cluster (7098793775610953753)+
+--------+------+------+-------+----+-----------+
Please confirm the cluster name to remove: patroni-cluster
You are about to remove all information in DCS for patroni-cluster, please type: "Yes I am aware": Yes I am aware
```
При этом, вместо `{{postgres_volume_name}}` следует подставить имя тома docker с данными PostgreSQL.  

8. Если позволяет место на диске, на ведущем узле кластера Patroni создать резервную копию тома docker с данными PostgreSQL, выполнив команду
```shell
docker run --rm -it -v {{ postgres_volume_name }}:/from \
  -v {{ postgres_volume_name }}-backup:/to busybox \
  sh -c "cd /from && cp -av . /to"
```
При этом, вместо `{{postgres_volume_name}}` следует подставить имя тома docker с данными PostgreSQL.  

9. Если места на диске недостаточно, по меньшей мере, сохранить каталог _pg_wal_, который может содержать журналы транзакций, которые ещё не были заархивированы на момент выключения СУБД, выполнив команду
```shell
docker run --rm -it -v {{ postgres_volume_name }}:/from \
  -v {{ postgres_volume_name }}-wal-backup:/to busybox \
  sh -c "cd /from/data/pg_wal && cp -av . /to"
```
При этом, вместо `{{postgres_volume_name}}` следует подставить имя тома docker с данными PostgreSQL.  

10. Удалить том docker с данными PostgreSQL на всех узлах кластера Patroni, выполнив на всех узлах команду
```shell
docker volume rm {{ postgres_volume_name }}
```
При этом, вместо `{{postgres_volume_name}}` следует подставить имя тома docker с данными PostgreSQL.  

11. Произвести развёртывание кластера Patroni, выполнив на узле управления Ansible команду
```shell
ansible-playbook -i inventory.ini 5_install_patroni.yml
```
12. Проверить целостность данных СУБД.
13. Включить автоматический запуск службы Patroni на всех узлах кластера Patroni, выполнив на узле управления Ansible команду
```shell
ansible all -i inventory.ini --become -a "systemctl enable patroni-docker"
```


### 5.4 Проверка данных после восстановления <a name="restore_check"/>
После восстановления данных СУБД из резервной копии необходимо, по меньшей мере, проверить целостность данных и индексов.  

Желательно настроить автоматическую проверку последней созданной резервной копии данных после завершения процедуры ежедневного резервного копирования путём восстановления данных из резервной копии на тестовый сервер.  

**ВНИМАНИЕ:** При проверке резервной копии данных путём восстановления данных из резервной копии на тестовый сервер следует использовать отдельную учётную запсиь для доступа к хранилищу данных S3 с доступом **только на чтение**, иначе данные из тестовой СУБД могут перезаписать резервные копии production СУБД. Также следует установить параметр **archive_mode=off** в разделе **postgresql** файла конфигурации _patroni.yml_ тестовой СУБД.

Для проверки целостности данных достаточно сделать дамп базы. Желательно также, чтобы при инициализации базы данных были включены контрольные суммы: [https://postgrespro.ru/docs/postgresql/14/app-initdb#APP-INITDB-DATA-CHECKSUMS](https://postgrespro.ru/docs/postgresql/14/app-initdb#APP-INITDB-DATA-CHECKSUMS).  

**ПРИМЕЧАНИЕ**: В случае запуска приведённых ниже команд проверки целостности данных и индексов внутри docker-контейнера Patroni, нет необходимости использовать команду `sudo -u postgres`, т.к. означенный контейнер выполняется с учётной записью пользователя **postgres**. В данном случае, например, вместо `sudo -u postgres pg_dumpall > /dev/null` следует использовать просто `pg_dumpall > /dev/null`.

Пример сценария проверки целостности данных СУБД:
```shell
if ! sudo -u postgres pg_dumpall > /dev/null; then
    echo 'pg_dumpall failed' >&2
    exit 125
fi
```

Проверка индексов может быть выполнена при помощи модуля PostgreSQL **amcheck**: [https://postgrespro.ru/docs/postgrespro/14/amcheck](https://postgrespro.ru/docs/postgrespro/14/amcheck).  

Сначала следует создать файл проверочного SQL-запроса _/tmp/amcheck.sql_ следующего содержания:
```sql
CREATE EXTENSION IF NOT EXISTS amcheck;
SELECT bt_index_check(c.oid), c.relname, c.relpages
FROM pg_index i
JOIN pg_opclass op ON i.indclass[0] = op.oid
JOIN pg_am am ON op.opcmethod = am.oid
JOIN pg_class c ON i.indexrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE am.amname = 'btree'
AND c.relpersistence != 't'
AND i.indisready AND i.indisvalid;
```
и установить владельца созданного файла - **postgres**, выполнив команду
```shell
chown postgres /tmp/amcheck.sql
```
Затем следует создать сценарий запуска проверок индексов всех доступных баз в СУБД _/tmp/amcheck.sh_ следующего содержания:
```shell
for DBNAME in $(psql -q -A -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    echo "Database: ${DBNAME}"
    psql -f /tmp/amcheck.sql -v 'ON_ERROR_STOP=1' ${DBNAME} && EXIT_STATUS=$? || EXIT_STATUS=$?
    if [ "${EXIT_STATUS}" -ne 0 ]; then
        echo "amcheck failed on DB: ${DBNAME}" >&2
        exit 125
    fi
done
```
и сделать его исполняемым, выполнив команду
```shell
chmod +x /tmp/amcheck.sh
```
После чего запустить сценарий проверки индексов, выполнив команду
```shell
sudo -u postgres /tmp/amcheck.sh >/dev/null
```
В случае ошибки сценарий выдаст сообщение об ошибке, содержащее имя базы данных, с которой есть проблемы, и завершится с кодом возврата, отличным от ``0``.


## 6 Добавление нового узла в кластер Patroni <a name="new_node"/>

### 6.1 Добавление нового узла в кластер Patroni с репликацией данных с ведущего узла кластера <a name="new_node_master_replication"/>
1. Перед добавлением нового узла в кластер следует убедиться, что на целевом хосте не существует том docker с именем, заданным в значении параметра **postgres_volume_name** в файле _ansible/group_vars/all.yml_, так как существующий том может содержать данные PostgreSQL, которые могут помешать добавлению нового узла в кластер.  

Для проверки существующих томов docker можно использовать команду
```shell
docker volume ls
```  
Для удаления тома docker можно использовать команду
```shell
docker volume rm <ИМЯ_ТОМА>
```
2. Для добавления нового узла в кластер с репликацией данных СУБД с ведущего узла кластера сначала следует установить в файле _ansible/group_vars/all.yml_ параметр **patroni_bootstrap_method** в значение **initdb**.
3. Далее следует добавить имя нового узла, а также его публичный и приватный адреса в раздел **[all]** файла _ansible/inventory.ini_.
4. Затем добавить имя нового узла в раздел **[patroni]** файла _ansible/inventory.ini_.
5. Если на новый узел требуется установить сервер Consul, следует добавить имя нового узла в раздел **[consul]** файла _ansible/inventory.ini_. При этом следует иметь в виду, что число серверов в кластере Consul должно быть **нечётным** в целях соблюдения консенсуса в случаях нарушения сетевой связности.
6. Если устанавливать сервер Consul на новый узел не требуется, следует добавить имя нового узла в раздел **[consul_client]** файла _ansible/inventory.ini_ для установки клиента Consul на данный узел.
7. Если в целевой сети развёртывания отсутствует служба DNS, то для того, чтобы узлы кластера могли связываться по именам, следует перегенерировать файлы **/etc/hosts**, выполнив команду
```shell
ansible-playbook -i inventory.ini 1_populate_hosts.yml
```
8. Для установки сервера или клиента Consul следует выполнить команду
```shell
ansible-playbook -i inventory.ini 4_install_consul.yml --limit=<ИМЯ_УЗЛА>
```
9. Для добавления нового узла в кластер Patroni следует выполнить команду
```shell
ansible-playbook -i inventory.ini 5_install_patroni.yml --limit=<ИМЯ_УЗЛА>
```
10. Проверить состояние репликации данных СУБД, выполнив на новом узле кластера команду
```shell
$ docker logs -f patroni
2022-05-16 13:46:28,503 INFO: trying to bootstrap from leader 'pg2'
2022-05-16 13:46:28,505 INFO: Lock owner: pg2; I am pg3
2022-05-16 13:46:28,511 WARNING: Could not register service: unknown role type uninitialized
2022-05-16 13:46:28,524 INFO: bootstrap from leader 'pg2' in progress
...
2022-05-16 13:47:13,706 INFO: replica has been created using basebackup
2022-05-16 13:47:13,707 INFO: bootstrapped from leader 'pg2'
...
2022-05-16 13:47:15,386 INFO: no action. I am (pg3), a secondary, and following a leader (pg2)
```
По завершении репликации должно появиться сообщение вида
```
INFO: no action. I am (pg3), a secondary, and following a leader (pg2)
```

### 6.2 Добавление нового узла в кластер Patroni с загрузкой данных из S3 <a name="new_node_s3"/>
**TBD:** [https://patroni.readthedocs.io/en/latest/replica_bootstrap.html#building-replicas](https://patroni.readthedocs.io/en/latest/replica_bootstrap.html#building-replicas)


## 7 Миграция одиночной установки PostgreSQL в кластер Patroni <a name="migrate_from_single"/>

### 7.1 Миграция одиночной установки PostgreSQL в кластер Patroni через резервную копию данных <a name="migrate_from_single_s3"/>
1. На исходном одиночном сервере PostgreSQL настроить резервное копирование в хранилище данных S3 при помощи WAL-G, как описано в [README.single-server-backup.md](README.single-server-backup.md).
2. Создать полную резервную копию данных исходной СУБД в S3.
3. Остановить приложения или запретить подключение клиентов к исходному серверу СУБД PostgreSQL при помощи настроек доступа в файле _pg_hba.conf_ или при помощи межсетевого экрана.
4. Развернуть кластер Patroni с инициализацией СУБД из резервной копии в S3. Для этого перед развёртыванием необходимо установить в файле _ansible/group_vars/all.yml_ параметр **patroni_bootstrap_method** в значение **walg**. Кроме того, для установки клиента Consul на узлы серверов приложений, следует добавить означенные узлы в группу **consul_client** в файле _ansible/inventory.ini_.
5. Проверить работоспособность кластера Patroni.
6. Перенастроить приложения на работу с кластером Patroni.
7. Запустить приложения.


### 7.2 Миграция одиночной установки PostgreSQL в кластер Patroni с обновлением базы данных <a name="migrate_from_single_upgrade"/>
При миграции существующего одиночного сервера PostgreSQL в кластер Patroni/Consul сначала производится развёртывание кластера, состоящего из одного узла, в соответствии с разделами 2 и 3. Затем, при необходимости, производится развёртывание реплик в соответствии с разделом 6.  

Во время развёртывания плейбук Ansible **5_install_patroni.yml** автоматически определит, что том docker содержит данные СУБД PostgreSQL, создаст роли СУБД, необходимые для работы Patroni, и, при необходимости, может выполнить обновление мажорной версии базы данных PostgreSQL с использованием команды **pg_upgrade**, а также выполнить обновление расширений PostGIS и TimescaleDB. Для автоматического обновления версии СУБД и расширений необходимо установить в файле _ansible/group_vars/all.yml_ параметр **postgres_db_autoupgrade** в значение **true**. В противном случае, если мажорная версия существующего одиночного сервера PostgreSQL отличается от мажорной версии, заданной параметром **postgres_major** в файле _ansible/group_vars/all.yml_, следует вручную обновить данные СУБД PostgreSQL при помощи команды **pg_upgrade**.

Для миграции существующего одиночного сервера PostgreSQL в кластер Patroni/Consul следует выполнить нижеперечисленные действия.
1. Остановить приложения или запретить подключение клиентов к мигрируемому серверу СУБД PostgreSQL при помощи настроек доступа в файле _pg_hba.conf_ или при помощи межсетевого экрана.
2. Остановить мигрируемый сервер PostgreSQL.
3. Если мигрируемый сервер PostgreSQL выполняется в контейнере docker, следует также удалить остановленный контейнер, выполнив команду
```shell
docker rm <ID_контейнера>
```
4. Выполнить резервное копирование тома docker, содержащего данные мигрируемой СУБД PostgreSQL, при помощи команды  
```shell
docker run --rm -it -v <ИМЯ_ИСХОДНОГО_ТОМА>:/from \
 -v <ИМЯ_КОПИИ_ТОМА>:/to busybox \
 sh -c "cd /from && cp -av . /to"
```
5. Выполнить подготовительные действия, указанные в разделе 2, добавив при этом адреса существующего одиночного сервера PostgreSQL в разделы **[all]**, **[consul]**, **[patroni]** файла _ansible/inventory.ini_.
6. Установить в файле _ansible/group_vars/all.yml_ параметр **patroni_bootstrap_method** в значение **initdb**.
7. Указать имя существующего тома docker, содержащего базу данных мигрируемого сервера PostgreSQL, в значении параметра **postgres_volume_name** в файле _ansible/group_vars/all.yml_.
8. Выполнить развёртывание кластера, состоящего из одного узла, как указано в разделе 3.
9. При необходимости выполнить развёртывание реплик, как указано в разделе 6.
10. Проверить работоспособность кластера Patroni.
11. Запустить приложения или убрать запрет подключения клиентов к серверу СУБД PostgreSQL.


## 8 Возможные проблемы <a name="issues"/>

### 8.1 При первом запуске кластера СУБД после установки не запускается Postgres<a name="postgres_not_starting"/>
При этом, в журнале Patroni присутствуют сообщения вида
```
2022-05-12 10:35:56,654 INFO: Lock owner: None; I am pg2
2022-05-12 10:35:56,656 INFO: Deregister service patroni-cluster/pg2
2022-05-12 10:35:56,657 INFO: waiting for leader to bootstrap
```
Ошибка может возникнуть при переустановке кластера Patroni, когда кластер Consul "запомнил" информацию о предыдущей установке Patroni.
В этом случае надо переинициализировать данные Patroni в кластере Consul.  

**Решение проблемы**  
Сначала необходимо получить идентификатор кластера Patroni, выполнив команду
```shell
docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml list
```
Пример вывода вышеозначенной команды (идентификатор кластера - patroni-cluster):
```
+--------+-------------+---------+---------+----+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+ Cluster: patroni-cluster (7096788110601269273) -----------+
| pg1    | 10.1.0.13   | Replica | stopped |    |   unknown |
| pg2    | 10.1.0.32   | Replica | stopped |    |   unknown |
| pg3    | 10.1.0.9    | Replica | stopped |    |   unknown |
+--------+-------------+---------+---------+----+-----------+
```
Затем удалить кластер Patroni, выполнив команду
```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml remove patroni-cluster
Please confirm the cluster name to remove: patroni-cluster
You are about to remove all information in DCS for patroni-cluster, please type: "Yes I am aware": Yes I am aware
```  

### 8.2 После перезапуска узла кластера СУБД состояние узла кластера - start failed <a name="postgres_start_failed"/>
Пример результата проверки состояния узлов кластера СУБД:
```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml list
+--------+-------------+---------+--------------+----+-----------+
| Member | Host        | Role    | State        | TL | Lag in MB |
+ Cluster: patroni-cluster (7096851968026091552) ----+-----------+
| pg1    | 10.1.0.13   | Replica | start failed |    |   unknown |
| pg2    | 10.1.0.32   | Leader  | running      | 32 |           |
| pg3    | 10.1.0.9    | Replica | running      | 32 |         0 |
+--------+-------------+---------+--------------+----+-----------+
```
При этом, в журнале Patroni на проблемном узле кластера присутствуют сообщения вида
```shell
$ docker logs patroni
...
2022-05-16 08:35:08,074 INFO: master: history=23        0/210000A0      no recovery target specified
28      0/3A0000A0      no recovery target specified
29      0/3B0000A0      no recovery target specified
2022-05-16 08:35:08,074 INFO: Lock owner: pg2; I am pg1
2022-05-16 08:35:08,076 INFO: starting as a secondary
2022-05-16 08:35:08,238 INFO: postmaster pid=982
2022-05-16 08:35:08.242 UTC - 1 - 982 -  - @ - 0LOG:  redirecting log output to logging collector process
2022-05-16 08:35:08.242 UTC - 2 - 982 -  - @ - 0HINT:  Future log output will appear in directory "pg_log".
localhost:5432 - rejecting connections
localhost:5432 - rejecting connections
localhost:5432 - rejecting connections
localhost:5432 - no response
2022-05-16 08:35:17,747 INFO: Lock owner: pg2; I am pg1
2022-05-16 08:35:17,748 INFO: failed to start postgres
```
Кроме того, в журнале PostgreSQL присутствуют сообщения вида
```shell
$ docker exec -it patroni \
  cat /var/lib/postgresql/data/pg_log/postgresql-Thu.log
...
2022-05-16 08:36:28.112 UTC - 1 - 1057 -  - @ - 0LOG:  database system was shut down in recovery at 2022-05-16 08:01:11 UTC
2022-05-16 08:36:28.112 UTC - 2 - 1057 -  - @ - 0LOG:  entering standby mode
2022-05-16 08:36:28.112 UTC - 3 - 1057 -  - @ - 0LOG:  invalid resource manager ID in primary checkpoint record
2022-05-16 08:36:28.112 UTC - 4 - 1057 -  - @ - 0PANIC:  could not locate a valid checkpoint record
...
```  

**Решение проблемы**  
Пусть, для примера, сбой произошёл на узле кластера pg1 с IP-адресом 10.1.0.13. Сначала следует убедиться, что с ведущего узла кластера СУБД доступен HTTP API Patroni на проблемном узле кластера. Для проверки доступа
на **ведущем** узле кластера СУБД следует выполнить команду
```shell
$ docker exec -it patroni curl http://10.1.0.13:8008/
{"state": "starting", "role": "replica", "dcs_last_seen": 1652692282, "database_system_identifier": "7096851968026091552", "patroni": {"version": "2.1.3", "scope": "patroni-cluster"}}
```
Если узел недоступен - исправить проблемы, связанные с сетью.  

Затем следует переинициализировать проблемный узел
кластера, выполнив на **ведущем** узле кластера СУБД команду
```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml reinit patroni-cluster pg1
+--------+-------------+---------+--------------+----+-----------+
| Member | Host        | Role    | State        | TL | Lag in MB |
+ Cluster: patroni-cluster (7096851968026091552) ----+-----------+
| pg1    | 10.1.0.13   | Replica | running      | 32 |         0 |
| pg2    | 10.1.0.32   | Leader  | running      | 32 |           |
| pg3    | 10.1.0.9    | Replica | start failed |    |   unknown |
+--------+-------------+---------+--------------+----+-----------+
Are you sure you want to reinitialize members pg1? [y/N]: y
Success: reinitialize for member pg1
```
После чего следует убедиться, что узел кластера находится в состоянии **running**, выполнив команду
```shell
$ docker exec -it patroni patronictl -c /var/lib/postgresql/patroni.yml list
+--------+-------------+---------+---------+----+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+ Cluster: patroni-cluster (7096851968026091552) -----------+
| pg1    | 10.1.0.13   | Replica | running | 33 |         0 |
| pg2    | 10.1.0.32   | Replica | running | 33 |         0 |
| pg3    | 10.1.0.9    | Leader  | running | 33 |           |
+--------+-------------+---------+---------+----+-----------+
```


## 9 Дополнительная информация <a name="info"/>

### Consul
1. Настройка разрешения имён узлов кластера посредством Consul
- Forward DNS for Consul Service Discovery - https://learn.hashicorp.com/tutorials/consul/dns-forwarding
- systemd-resolved Setup Script - https://github.com/hashicorp/terraform-aws-consul/tree/master/modules/setup-systemd-resolved
- How to get consul-agent and systemd.resolvd to co-exist - https://gist.github.com/kquinsland/5cdc63614a581d9b392f435740b58729
2. Кеширование DNS в Consul - https://learn.hashicorp.com/tutorials/consul/dns-caching

### Patroni
1. Описание Patroni - https://habr.com/en/post/504044/
2. Описание параметров Patroni - https://github.com/zalando/patroni/blob/master/docs/SETTINGS.rst
3. Настройка параметров PostgreSQL в Patroni - https://blog.dbi-services.com/patroni-operations-changing-parameters/

### WAL-G
1. WAL-G: бэкапы и восстановление СУБД PostgreSQL - https://habr.com/en/post/506610/
2. Общее описание WAL-G - https://github.com/wal-g/wal-g
3. Описание WAL-G для PostgreSQL - https://github.com/wal-g/wal-g/blob/master/docs/PostgreSQL.md#configuration
4. Описание параметров настройки хранения данных WAL-G - https://github.com/wal-g/wal-g/blob/master/docs/STORAGES.md
5. Описание параметров PostgreSQL в части WAL - https://postgrespro.ru/docs/postgrespro/14/runtime-config-wal
6. Описание параметров PostgreSQL в части репликации - https://postgrespro.ru/docs/postgrespro/14/runtime-config-replication
