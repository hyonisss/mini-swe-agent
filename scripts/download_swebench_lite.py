#!/usr/bin/env python3
"""Download a SWE-bench dataset for offline / corporate-environment use.

Two modes:
  --url    Download a JSONL file directly from a URL (simplest, no HuggingFace)
  --subset Download a named HuggingFace subset (requires internet + HF access)

Run on a machine with internet access, then transfer the file/directory to
your air-gapped environment.

Usage:
    # From a direct URL (e.g. custom JSONL on GitHub):
    python scripts/download_swebench_lite.py \\
        --url https://raw.githubusercontent.com/joyon1104/coding-agent-eval/master/data/swebench_lite_test2.jsonl \\
        --output ./data/swebench_lite_test2.jsonl

    # From HuggingFace:
    python scripts/download_swebench_lite.py --subset lite --output ./data/swebench_lite
"""

import argparse
import urllib.request
from pathlib import Path

SUBSET_MAPPING = {
    "lite": "princeton-nlp/SWE-Bench_Lite",
    "verified": "princeton-nlp/SWE-Bench_Verified",
    "full": "princeton-nlp/SWE-Bench",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--url", help="Direct URL to a JSONL file")
    group.add_argument("--subset", choices=list(SUBSET_MAPPING), help="HuggingFace subset name")
    parser.add_argument("--output", required=True, help="Local path to save the dataset")
    args = parser.parse_args()

    output_path = Path(args.output)

    if args.url:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {args.url} ...")
        urllib.request.urlretrieve(args.url, output_path)
        print(f"Saved to {output_path.resolve()}")
        print(f"\nTo use in evaluation:\n  mini-extra swebench --subset {output_path.resolve()} ...")
    else:
        from datasets import load_dataset

        dataset_id = SUBSET_MAPPING[args.subset]
        output_path.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {dataset_id} from HuggingFace ...")
        ds = load_dataset(dataset_id)
        print(f"Available splits: {list(ds.keys())}")
        ds.save_to_disk(str(output_path))
        print(f"Saved to {output_path.resolve()}")
        print(f"\nTo use in evaluation:\n  mini-extra swebench --subset {output_path.resolve()} --split dev ...")


if __name__ == "__main__":
    main()
