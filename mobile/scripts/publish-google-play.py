import argparse

from google.auth import load_credentials_from_file
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload


parser = argparse.ArgumentParser()
parser.add_argument('--credentials', required=True)
parser.add_argument('--bundle', required=True)
parser.add_argument('--track', choices=['internal', 'alpha', 'beta', 'production'], default='internal')
args = parser.parse_args()

package = 'sh.abstractapp.mobile'
credentials, _ = load_credentials_from_file(
    args.credentials, scopes=['https://www.googleapis.com/auth/androidpublisher']
)
api = build('androidpublisher', 'v3', credentials=credentials, cache_discovery=False)
edit = api.edits().insert(packageName=package, body={}).execute()
edit_id = edit['id']
bundle = api.edits().bundles().upload(
    packageName=package,
    editId=edit_id,
    media_body=MediaFileUpload(args.bundle, mimetype='application/octet-stream', resumable=True),
).execute()
api.edits().tracks().update(
    packageName=package,
    editId=edit_id,
    track=args.track,
    body={'releases': [{'versionCodes': [str(bundle['versionCode'])], 'status': 'completed'}]},
).execute()
api.edits().commit(packageName=package, editId=edit_id).execute()
print(f"Published version {bundle['versionCode']} to {args.track}")
