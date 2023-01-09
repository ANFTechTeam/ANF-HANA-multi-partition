# ANF-HANA-multi-partition
A PowerShell script to automate the deployment of Azure NetApp Files application volume groups for SAP HANA using a multi-partition layout.

## Description
For larger HANA systems, such as the new 24TiB VMs, a single data volume does not deliver enough performance and capacity. For this scenario, SAP supports 'multiple partitions' (MP) where the SAP HANA database is striped across multiple volumes. This script automates the deployment of multiple Azure NetApp Files application volumes groups (AVGs) to support SAP HANA databases striped across one or more data volume partitions.

## Order of Operations
    1. Create base AVG which includes 'shared', 'log', and temporary 'data' volumes.
    1. Create additional AVGs which include 'data' and temporary 'log' volume.
    1. Delete temporary 'data' and 'log' volumes.

## Example
In the following scenario a multi-partition configuration is created with 4 data partitions.

### Initially the following AVGs and child volumes are created:
    - AVG: SAP-HANA-SH1-shared-log
        - volume: SH1-shared
        - volume: SH1-log-mnt00001
        - volume: **SH1-data-temp**
    - AVG: SAP-HANA-SH1-part1-mnt00001
        - volume: SH1-data-part1-mnt00001
        - volume: **SH1-log1-mnt00001-temp**
    - AVG: SAP-HANA-SH1-part2-mnt00001
        - volume: SH1-data-part2-mnt00001
        - volume: **SH1-log2-mnt00001-temp**
    - AVG: SAP-HANA-SH1-part3-mnt00001
        - volume: SH1-data-part3-mnt00001
        - volume: **SH1-log3-mnt00001-temp**
    - AVG: SAP-HANA-SH1-part4-mnt00001
        - volume: SH1-data-part4-mnt00001
        - volume: **SH1-log4-mnt00001-temp**
Note: **bold** volumes are to be deleted.

### Once the AVGs and child volumes are created successfully, the temporary volumes are deleted. The AVGs and remaining volumes are as follows:
    - AVG: SAP-HANA-SH1-shared-log
        - volume: SH1-shared
        - volume: SH1-log-mnt00001
    - AVG: SAP-HANA-SH1-part1-mnt00001
        - volume: SH1-data-part1-mnt00001
    - AVG: SAP-HANA-SH1-part2-mnt00001
        - volume: SH1-data-part2-mnt00001
    - AVG: SAP-HANA-SH1-part3-mnt00001
        - volume: SH1-data-part3-mnt00001 
    - AVG: SAP-HANA-SH1-part4-mnt00001
        - volume: SH1-data-part4-mnt00001