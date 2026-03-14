ChronoFlow patch

Changes:
- Event modal: location / color / notes(description) / share button
- Share request modal + pending requests list
- Friend/member DM
- ChatGPT-like expanding composer
- Group member owner detection fix
- Events support location/color

How to apply (from project root):
  unzip -o chronoflow_feature_patch_v4.zip -d .
  bin/rails db:migrate
  bin/rails s
Then hard reload browser (Ctrl+Shift+R)
