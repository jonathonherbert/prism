package collectors

import agent._
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.{GetBucketLocationRequest, ListBucketsRequest, S3Exception, Bucket => AWSBucket}

import scala.language.reflectiveCalls
import conf.AWS
import controllers.routes
import org.joda.time.DateTime
import play.api.mvc.Call
import utils.Logging

import scala.jdk.CollectionConverters._
import scala.language.postfixOps
import scala.util.Try
import scala.util.control.NonFatal


class BucketCollectorSet(accounts: Accounts) extends CollectorSet[Bucket](ResourceType("bucket"), accounts) {
  val lookupCollector: PartialFunction[Origin, Collector[Bucket]] = {
    case amazon: AmazonOrigin => AWSBucketCollector(amazon, resource, amazon.crawlRate(resource.name))
  }
}

case class AWSBucketCollector(origin: AmazonOrigin, resource: ResourceType, crawlRate: CrawlRate) extends Collector[Bucket] with Logging {

  val client = S3Client
    .builder()
    .credentialsProvider(origin.credentials.providerV2)
    .region(origin.awsRegionV2)
    .overrideConfiguration(AWS.clientConfigV2)
    .build()

  def crawl: Iterable[Bucket] = {
    val request = ListBucketsRequest.builder().build()
    client.listBuckets(request).buckets().asScala
      .flatMap {
        Bucket.fromApiData(_, client)
      }
  }
}

object Bucket {

  private def arn(bucketName: String) = s"arn:aws:s3:::$bucketName" 

  def fromApiData(bucket: AWSBucket, client: S3Client): Option[Bucket] = {
    val bucketName = bucket.name
    try {
      // TODO: not sure if we still need the if block that checked the bucket location vs the client's region
      val bucketRegion = client.getBucketLocation(GetBucketLocationRequest.builder().bucket(bucketName).build()).locationConstraintAsString()
        Some(Bucket(
          arn = arn(bucketName),
          name = bucketName,
          region = bucketRegion,
          createdTime = Try(new DateTime(bucket.creationDate())).toOption
        ))
    } catch {
      case e:S3Exception if e.awsErrorDetails.errorCode == "NoSuchBucket" => None
      case e:S3Exception if e.awsErrorDetails.errorCode == "AuthorizationHeaderMalformed" => None
      case NonFatal(t) =>
        throw new IllegalStateException(s"Failed when building info for bucket $bucketName", t)
    }
  }
}

case class Bucket(
  arn: String,
  name: String,
  region: String,
  createdTime: Option[DateTime]
) extends IndexedItem {
  override def callFromArn: (String) => Call = arn => routes.Api.bucket(arn)
}