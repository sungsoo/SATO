#! /bin/bash

# Configuring lib and include directories
usage(){
  echo -e "loaddata.sh [options]\n \
  -d PATH_TO_DATA, --data=PATH_TO_DATA \t The HDFS path to the raw data \n \
  -p HDFS_PATH_PREFIX, --prefix=HDFS_PATH_PREFIX \t directory path to the include locations \n \
  -g GEOM_ID, --geomid=GEOM_ID \t The field (position) of the geometry field (starts from 1) \n \
  -s SEPARATOR, --separator=SEPARATOR \t OPTIONAL - The seperator/delimiter used to separate fields in the original dataset. The default value is tab. \
  -r SAMPLING_RATIO, --ratio=SAMPLING_RATIO \t OPTIONAL - The sampling ratio we will use to partition the data. Default value is 1.0.\
  -m PARTITION_METHOD, --method=PARTITION_METHOD \t OPTIONAL - The partitioning method. The default method is fixed grid partitioning. Options include: fg (fixed grid), bsp (binary space partitioning), sfc (space filling curve).
"
 # -i OBJECT_ID, --obj_id=OBJECT_ID \t The field (position) of the object ID \n \
  exit 1
}

# Default empty values
datapath=""
prefixpath=""
geomid=""
delimiter=""
sample_ratio=1
method="fg"

while : 
do
    case $1 in
        -h | --help | -\?)
          usage;
          exit 0
          ;;
        -d | --data)
          datapath=$2
          shift 2
          ;;
        --data=*)
          datapath=${1#*=}
          shift
          ;;
        -p | --prefix)
          prefixpath=$2
          shift 2
          ;;
        --prefix=*)
          prefixpath=${1#*=}
          shift
          ;;
        -g | --geomid)
          geomid=$2
          shift 2
          ;;
        --geomid=*)
          geomid=${1#*=}
          shift
          ;;
        -i | --obj_id)
          obj_id=$2
          shift 2
          ;;
        --obj_id=*)
          obj_id=${1#*=}
          shift
          ;;
        -s | --separator)
          delimiter=$2
          shift 2
          ;;
        --separator=*)
          delimiter=${1#*=}
          shift
          ;;
        -r | --ratio)
          sample_ratio=$2
          shift 2
          ;;
        --ratio=*)
          sample_ratio=${1#*=}
          shift
          ;;
        -m | --method)
          method=$2
          shift 2
          ;;
        --method=*)
          method=${1#*=}
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "Unknown option: $1" >&2
          shift
          ;;
        *) # Done
          break
          ;;
     esac
done

if [ ! "$datapath" ]; then
  echo "ERROR: Missing path to the data. See --help" >&2
  exit 1
fi
if [ ! "$prefixpath" ]; then
  echo "ERROR: Missing the target HDFS prefix path. See --help" >&2
  exit 1
fi

if [ ! "$geomid" ]; then
  echo "ERROR: Missing the geometry id (field number). See --help" >&2
  exit 1
fi

# Setting global variables
HJAR=${HADOOP_STREAMING_PATH}/hadoop-streaming.jar

# Load the SATO configuration file
source ../sato.cfg
LD_CONFIG_PATH=${LD_LIBRARY_PATH}:${SATO_LIB_PATH}


# Creating the path with the HDFS prefix
hdfs dfs -mkdir -p ${prefixpath}



INPUT_1=${datapath}
OUTPUT_1=${prefixpath}/sampledtsv
MAPPER_1=samplefilter.py
MAPPER_1_PATH=../step_sample/${MAPPER_1}


# Remove the output directory
hdfs dfs -rm -f -r ${OUTPUT_1}
echo "Starting the sampling/filtering step"

# Sample / Filter step:
# This step will convert the original data into a tab-separated format (tsv file).
hadoop jar ${HJAR} -input ${INPUT_1} -output ${OUTPUT_1} -file ${MAPPER_1_PATH} -mapper "${MAPPER_1} ${delimiter} 1" -reducer None -numReduceTasks 0

if [  $? -ne 0 ]; then
   echo "Data conversion has failed!"
   exit 1
fi

echo "Finished the filtering/sampling step"


# Extract the mbbs from spatial objects
INPUT_2=${OUTPUT_1}
OUTPUT_2=${prefixpath}/mbb
MAPPER_2=mbbextractor
MAPPER_2_PATH=../tiler/mbbextractor

# Remove the output directory
hdfs dfs -rm -f -r ${OUTPUT_2}

# This is out-dated
# Optional depending on whether the sampling ratio is 1.0
#if [ "${sample_ratio}" -lt 1 ]; then
#    # perform sampling
#    hadoop jar ${HJAR} -input ${INPUT_1} -output ${OUTPUT_1} -file ${MAPPER_1_PATH} -mapper "${MAPPER_1} ${delimiter} ${sample_ratio}" -reducer None -numReduceTasks 0
#fi

echo "Extracting MBRs from objects"
hadoop jar ${HJAR} -input ${INPUT_2} -output ${OUTPUT_2} -file ${MAPPER_2_PATH} -mapper "${MAPPER_2} ${geomid} ${sample_ratio}" -reducer None -cmdenv LD_LIBRARY_PATH=${LD_CONFIG_PATH} -numReduceTasks 0

if [ $? -ne 0 ]; then
   echo "Extracting MBRs has failed!"
   exit 1
fi

echo Done extracting object MBRs""

# Determine the min, max dimensions of the space
INPUT_3=${OUTPUT_2}
OUTPUT_3=${prefixpath}/mbbstat
MAPPER_3=getSpaceDimension.py
MAPPER_3_PATH=../step_analyze/getSpaceDimension.py
REDUCER_3=${MAPPER_3}

echo "Retrieving space dimension"
# Remove the output directory
hdfs dfs -rm -f -r ${OUTPUT_3}
hadoop jar ${HJAR} -input ${INPUT_3} -output ${OUTPUT_3} -file ${MAPPER_3_PATH} -mapper "${MAPPER_3} 1" -reducer "${MAPPER_3} 0" -numReduceTasks 1

# Normalize the space using the dimension obtained from above
TEMP_FILE_NAME=tmpSpaceDimension
rm $TEMP_FILE_NAME
hdfs dfs -cat ${OUTPUT_3}/part-00000 > ${TEMP_FILE_NAME}

min_x=`(cat ${TEMP_FILE_NAME} | cut -f1)`
min_y=`(cat ${TEMP_FILE_NAME} | cut -f2)`
max_x=`(cat ${TEMP_FILE_NAME} | cut -f3)`
max_y=`(cat ${TEMP_FILE_NAME} | cut -f4)`
num_objects=`(cat ${TEMP_FILE_NAME} | cut -f5)`

rm -f ${TEMP_FILE_NAME}

TEMP_CFG_FILE=data.cfg

# Outputting the space dimensions
echo ${min_x}
echo ${max_x}
echo ${min_y}
echo ${max_y}

# Write the config file
echo "dataminx=${min_x}" > ${TEMP_CFG_FILE}
echo "dataminy=${min_y}" >> ${TEMP_CFG_FILE}
echo "datamaxx=${max_x}" >> ${TEMP_CFG_FILE}
echo "datamaxy=${max_y}" >> ${TEMP_CFG_FILE}
echo "numobjects=${num_objects}" >> ${TEMP_CFG_FILE}
echo "geomid=${geomid}" >> ${TEMP_CFG_FILE}

# Normalize the mbbs
INPUT_4=${OUTPUT_2}
OUTPUT_4=${prefixpath}/mbbnorm
MAPPER_4=mbbnorm.py
MAPPER_4_PATH=../step_analyze/mbbnorm.py

hdfs dfs -rm -f -r ${OUTPUT_4}

echo "Normalizing MBBs"
hadoop jar ${HJAR} -input ${INPUT_4} -output ${OUTPUT_4} -file ${MAPPER_4_PATH} -mapper "${MAPPER_4} ${min_x} ${min_y} ${max_x} ${max_y}" -reducer None -numReduceTasks 0

if [  $? -ne 0 ]; then
   echo "Normalizing MBB has failed!"
   exit 1
fi

# Determine the optimal bucket count
totalSize=`(hdfs dfs -du -s "${datapath}" | cut -d\  -f1)`
echo "Total size in bytes: "${totalSize}
echo "Number of objects: "${num_objects}
avgObjSize=$((totalSize / num_objects))

blockSize=1600000
partitionSize=$((blockSize / avgObjSize))

echo "partitionsize=${partitionSize}" >> ${TEMP_CFG_FILE}
INPUT_MBB_FILE=mbbnormfile

PARTITION_FILE=partfile

hdfs dfs -cat ${prefixpath}/mbbnorm/* > ${INPUT_MBB_FILE}

# Partition data
if [ "$method" == "fg" ]; then
   ../step_tear/fg/serial/fgNoMbb.py ${min_x} ${min_y} ${max_x} ${max_y} ${partitionSize} ${num_objects} > ${PARTITION_FILE}
fi

if [ "$method" == "bsp" ]; then
   ../step_tear/bsp/serial/bsp -b {max_y} ${partition_size} -i ${INPUT_MBB_FILE} > ${PARTITION_FILE}
fi

# Remove temporary files
rm ${INPUT_MBB_FILE}

INPUT_5=${OUTPUT_1}
OUTPUT_5=${prefixpath}/data
MAPPER_5=partitionMapper
MAPPER_5_PATH=../tiler/partitionMapper
REDUCER_5=hgdeduplicater.py
REDUCER_5_PATH=../joiner/hgdeduplicater.py

hdfs dfs -rm -f -r ${OUTPUT_5}

echo "Mapping data to create physical partitions"
#Map the data back to its partition
hadoop jar ${HJAR} -libjars ../libjar/customLibs.jar -outputformat com.custom.CustomMultiOutputFormat  -input ${INPUT_1} -output ${OUTPUT_5} -file ${MAPPER_5_PATH} -file ${REDUCER_5_PATH} -file ${PARTITION_FILE}  -mapper "${MAPPER_5} ${min_x} ${min_y} ${max_x} ${max_y} ${geomid}  ${PARTITION_FILE}" -reducer "${REDUCER_5} cat" -cmdenv LD_LIBRARY_PATH=${LD_CONFIG_PATH} -numReduceTasks 1

if [  $? -ne 0 ]; then
   echo "Mapping data back to its partition has failed!"
   exit 1
fi


# Denormalize the MBB file and copy them to HDFS
python ../step_tear/denormalize.py ${PARTITION_FILE} ${PARTITION_FILE}.denorm
# Copy the partition region mbb file onto HDFS
hdfs dfs -put ${PARTITION_FILE}.denorm ${prefixpath}/${PARTITION_FILE}

# Copy the config file into HDFS
hdfs dfs -put ${TEMP_CFG_FILE} ${prefixpath}/

#TEMP_FILE_MERGE=/tmp/satomerge
# Merge small files together
#cat "${PARTITION_FILE}" | cut -f1 | { while read line
#do echo $line;
# hdfs dfs -getmerge ${prefixpath}/data/${line} ${TEMP_FILE_MERGE};
# hdfs dfs -rm -f -r  ${prefixpath}/data/${line};
# hdfs dfs -put ${TEMP_FILE_MERGE} ${prefixpath}/data/${line};
# rm ${TEMP_FILE_MERGE};
#done 
#}