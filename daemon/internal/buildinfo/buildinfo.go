package buildinfo

type Metadata struct {
	Version string `json:"version"`
	BuildID string `json:"buildId"`
}

var (
	Version = "dev"
	BuildID = "dev"
)

func Current() Metadata {
	return Metadata{
		Version: Version,
		BuildID: BuildID,
	}
}
