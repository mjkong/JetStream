#!/bin/bash
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# This script will do the following:
# - Finetuning the MaxText compatible checkpoint (converted from original checkpoints) with AQT
# - Convert the AQT-finetuned checkpoints to unscanned checkpoints for inference
# TPU device requirements:
# - For llama2-7b, it requires at least a v5e-8 TPU VM.
# - For llama2-13B/70b, it requires a v4-128 TPU VM.
set -ex

idx=$(date +%Y-%m-%d-%H-%M)
# Modify the `MODEL` and `MODEL_VARIATION` based on the model you use.
export MODEL=$1
export MODEL_VARIATION=$2
export MODEL_NAME=${MODEL}-${MODEL_VARIATION}

# After downloading checkpoints, copy them to GCS bucket at $CHKPT_BUCKET \
# Please use seperate GCS paths for uploading open source model weights ($CHKPT_BUCKET) and MaxText compatible weights ($MODEL_BUCKET).
# Point these variables to a GCS bucket that you created.
# An example of CHKPT_BUCKET could be: gs://${USER}-maxtext/chkpt/${MODEL}/${MODEL_VARIATION}
export CHKPT_BUCKET=$3
export MODEL_BUCKET=gs://${USER}-maxtext

# Point `BASE_OUTPUT_DIRECTORY` to a GCS bucket that you created, this bucket will store all the files generated by MaxText during a run.
export BASE_OUTPUT_DIRECTORY=gs://${USER}-runner-maxtext-logs

# Point `DATASET_PATH` to the GCS bucket where you have your training data
export DATASET_PATH=gs://${USER}-maxtext-dataset

# Prepare C4 dataset for fine tuning: https://github.com/allenai/allennlp/discussions/5056
sudo gsutil -u $4 -m cp 'gs://allennlp-tensorflow-datasets/c4/en/3.0.1/*' ${DATASET_PATH}/c4/en/3.0.1/

# We define `CONVERTED_CHECKPOINT` to refer to the checkpoint subdirectory.
export CONVERTED_CHECKPOINT=${MODEL_BUCKET}/${MODEL}/${MODEL_VARIATION}/${idx}/0/items

# Fine tune the converted model checkpoints with AQT.
export RUN_NAME=finetune_aqt_${idx}

python3 MaxText/train.py \
MaxText/configs/base.yml \
run_name=${RUN_NAME} \
base_output_directory=${BASE_OUTPUT_DIRECTORY} \
dataset_path=${DATASET_PATH} \
steps=501 \
enable_checkpointing=True \
load_parameters_path=${CONVERTED_CHECKPOINT} \
model_name=${MODEL_NAME} \
per_device_batch_size=1 \
quantization=int8 \
checkpoint_period=100

# We will convert the `AQT_CKPT` to unscanned checkpoint in the next step.
export AQT_CKPT=${BASE_OUTPUT_DIRECTORY}/${RUN_NAME}/checkpoints/100/items

# Covert MaxText compatible AQT-fine-tuned checkpoints to unscanned checkpoints.
# Note that the `AQT_CKPT` is in a `scanned` format which is great for training but for efficient decoding performance we want the checkpoint in an `unscanned` format.
export RUN_NAME=${MODEL_NAME}_unscanned_chkpt_${idx}

JAX_PLATFORMS=cpu python MaxText/generate_param_only_checkpoint.py \
MaxText/configs/base.yml \
base_output_directory=${BASE_OUTPUT_DIRECTORY} \
load_parameters_path=${AQT_CKPT} \
run_name=${RUN_NAME} \
model_name=${MODEL_NAME} \
force_unroll=true
echo "Written MaxText unscanned checkpoint to ${BASE_OUTPUT_DIRECTORY}/${RUN_NAME}/checkpoints"

# We will use the unscanned checkpoints by passing `UNSCANNED_CKPT_PATH` into `LOAD_PARAMETERS_PATH` in the following sections.
export UNSCANNED_CKPT_PATH=${BASE_OUTPUT_DIRECTORY}/${RUN_NAME}/checkpoints/0/items
