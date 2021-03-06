require 'spec_helper'

describe Gitlab::BackgroundMigration::MigrateSystemUploadsToNewFolder do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive(:logger).and_return(Logger.new(nil))
  end

  describe '#perform' do
    it 'renames the path of system-uploads', truncate: true do
      upload = create(:upload, model: create(:empty_project), path: 'uploads/system/project/avatar.jpg')

      migration.perform('uploads/system/', 'uploads/-/system/')

      expect(upload.reload.path).to eq('uploads/-/system/project/avatar.jpg')
    end
  end
end
